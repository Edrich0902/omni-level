import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Per-app process-tap capture → gain/pan → per-stream EQ → per-destination mix buses → speakers.
@MainActor
public final class AudioEngineController: ObservableObject {
    public enum EngineState: Equatable {
        case stopped
        case running
        case error(String)
    }

    /// Stable destination key for mix buses (`nil` / empty = System Default).
    nonisolated public static let systemDefaultDestinationKey = ""

    @Published public private(set) var state: EngineState = .stopped
    @Published public private(set) var sampleRate: Double = 48_000
    @Published public private(set) var outputDeviceName: String = "Default"
    @Published public private(set) var inputDeviceName: String = "Default"
    @Published public private(set) var selectedOutputDeviceID: AudioObjectID = kAudioObjectUnknown
    @Published public private(set) var selectedInputDeviceID: AudioObjectID = kAudioObjectUnknown
    @Published public private(set) var isRouting = false
    @Published public private(set) var lastIOError: String?
    @Published public private(set) var activeStreamCount: Int = 0
    /// Human-readable active output destinations for the status line.
    @Published public private(set) var activeOutputSummary: String = ""
    @Published public private(set) var eqOverrideCount: Int = 0

    public let equalizer = EqualizerDSP()
    public let limiter = AutoPreAmpLimiter()
    public let mixer = GainPanMixer()
    public let levels = AudioLevels()
    /// Post-EQ / post-mix spectrum (primary / system-default bus).
    public let spectrum = SpectrumAnalyzer()
    /// Pre-EQ mix bus spectrum (material before the equalizer).
    public let spectrumInput = SpectrumAnalyzer()
    /// Per-app EQ editor meters — only the focused stream.
    public let focusedSpectrum = SpectrumAnalyzer()
    public let focusedSpectrumInput = SpectrumAnalyzer()
    public let processTaps = ProcessTapIO()
    public let devices = AudioDeviceManager()

    private var sharedMix: SharedMixState?
    private var outputBuses: [String: OutputBusContext] = [:]
    private var streamContexts: [StreamContext] = []
    private let eqOverrideTable = EQOverrideTable()
    private var debounceWorkItem: DispatchWorkItem?
    private var suppressDeviceRestart = false
    private var isStarting = false
    private var ioStatusTimer: Timer?
    private let log = Logger(subsystem: "com.omnilevel.app", category: "engine")
    private let spectrumFocusLock = OSAllocatedUnfairLock(initialState: pid_t(0))

    /// Thread-safe PID → override DSP map for the mix callback.
    final class EQOverrideTable: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private var map: [pid_t: EqualizerDSP] = [:]

        func get(_ pid: pid_t) -> EqualizerDSP? {
            lock.withLock { map[pid] }
        }

        func set(_ pid: pid_t, dsp: EqualizerDSP) {
            lock.withLock { map[pid] = dsp }
        }

        func remove(_ pid: pid_t) {
            lock.withLock { _ = map.removeValue(forKey: pid) }
        }

        func removeAll() {
            lock.withLock { map.removeAll() }
        }

        func snapshot() -> [pid_t: EqualizerDSP] {
            lock.withLock { map }
        }

        var count: Int {
            lock.withLock { map.count }
        }

        func forEachDSP(_ body: (EqualizerDSP) -> Void) {
            let values = lock.withLock { Array(map.values) }
            values.forEach(body)
        }
    }

    /// One capture stream (PID) with its own ring and HAL unit.
    final class StreamContext: @unchecked Sendable {
        let pid: pid_t
        let ring: StereoRingBuffer
        var unit: AudioComponentInstance?
        var left: UnsafeMutablePointer<Float>
        var right: UnsafeMutablePointer<Float>
        let maxFrames: Int
        var pullABL: UnsafeMutableAudioBufferListPointer
        var lastStatus: OSStatus = noErr
        var callbacks: UInt64 = 0
        var framesWithSignal: UInt64 = 0
        /// Empty string = System Default. Non-empty = specific device UID.
        var destinationKey: String = AudioEngineController.systemDefaultDestinationKey
        private let meterLock = OSAllocatedUnfairLock()
        /// Linear envelope (0…1), attack-fast / release-slow — not raw peak.
        private var meterEnvelope: Float = 0

        init(pid: pid_t, maxFrames: Int = 4_096, ringCapacity: Int = 16_384) {
            self.pid = pid
            self.maxFrames = maxFrames
            self.ring = StereoRingBuffer(capacityFrames: ringCapacity)
            self.left = .allocate(capacity: maxFrames)
            self.right = .allocate(capacity: maxFrames)
            left.initialize(repeating: 0, count: maxFrames)
            right.initialize(repeating: 0, count: maxFrames)
            let abl = AudioBufferList.allocate(maximumBuffers: 2)
            abl.unsafeMutablePointer.pointee.mNumberBuffers = 2
            self.pullABL = abl
        }

        /// Update loudness meter from a stereo buffer (RMS, not sample peak).
        func noteMeterSamples(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
            guard count > 0 else { return }
            var rmsL: Float = 0
            var rmsR: Float = 0
            vDSP_rmsqv(left, 1, &rmsL, vDSP_Length(count))
            vDSP_rmsqv(right, 1, &rmsR, vDSP_Length(count))
            let rms = max(rmsL, rmsR)

            meterLock.withLock {
                // Fast attack so the bar rises with the music; slower release so it falls smoothly.
                if rms >= meterEnvelope {
                    meterEnvelope = rms
                } else {
                    meterEnvelope = meterEnvelope * 0.88 + rms * 0.12
                }
                // Noise gate: near-silence / tap floor collapses to empty (avoids a stuck half bar).
                if meterEnvelope < 0.0035 { // ≈ −49 dBFS
                    meterEnvelope *= 0.55
                    if meterEnvelope < 0.0004 {
                        meterEnvelope = 0
                    }
                }
            }
        }

        func peakLeveldB() -> Float {
            let env = meterLock.withLock { meterEnvelope }
            guard env > 1e-6 else { return -60 }
            return max(-60, min(0, 20 * log10(env)))
        }

        deinit {
            left.deallocate()
            right.deallocate()
            free(pullABL.unsafeMutablePointer)
        }
    }

    /// Shared mixer / EQ / stream list for all output buses.
    final class SharedMixState: @unchecked Sendable {
        let equalizer: EqualizerDSP
        let limiter: AutoPreAmpLimiter
        let levels: AudioLevels
        let spectrum: SpectrumAnalyzer
        let spectrumInput: SpectrumAnalyzer
        let focusedSpectrum: SpectrumAnalyzer
        let focusedSpectrumInput: SpectrumAnalyzer
        let mixer: GainPanMixer
        private let streamsLock = OSAllocatedUnfairLock()
        private var streamsStorage: [StreamContext]
        private let overridesLock = OSAllocatedUnfairLock()
        private var overridesStorage: [pid_t: EqualizerDSP]
        private let focusLock = OSAllocatedUnfairLock()
        private var focusPIDStorage: pid_t = 0
        let maxFrames: Int

        init(
            equalizer: EqualizerDSP,
            limiter: AutoPreAmpLimiter,
            levels: AudioLevels,
            spectrum: SpectrumAnalyzer,
            spectrumInput: SpectrumAnalyzer,
            focusedSpectrum: SpectrumAnalyzer,
            focusedSpectrumInput: SpectrumAnalyzer,
            mixer: GainPanMixer,
            streams: [StreamContext],
            overrides: [pid_t: EqualizerDSP],
            focusPID: pid_t = 0,
            maxFrames: Int = 4_096
        ) {
            self.equalizer = equalizer
            self.limiter = limiter
            self.levels = levels
            self.spectrum = spectrum
            self.spectrumInput = spectrumInput
            self.focusedSpectrum = focusedSpectrum
            self.focusedSpectrumInput = focusedSpectrumInput
            self.mixer = mixer
            self.streamsStorage = streams
            self.overridesStorage = overrides
            self.focusPIDStorage = focusPID
            self.maxFrames = maxFrames
        }

        var streams: [StreamContext] {
            streamsLock.withLock { streamsStorage }
        }

        func setStreams(_ next: [StreamContext]) {
            streamsLock.withLock { streamsStorage = next }
        }

        func setOverrides(_ next: [pid_t: EqualizerDSP]) {
            overridesLock.withLock { overridesStorage = next }
        }

        func setFocusPID(_ pid: pid_t) {
            focusLock.withLock { focusPIDStorage = pid }
        }

        var focusPID: pid_t {
            focusLock.withLock { focusPIDStorage }
        }

        /// Override DSP only — nil means this stream should use the shared post-mix global EQ.
        func overrideEqualizer(for pid: pid_t) -> EqualizerDSP? {
            overridesLock.withLock { overridesStorage[pid] }
        }

        func equalizer(for pid: pid_t) -> EqualizerDSP {
            overrideEqualizer(for: pid) ?? equalizer
        }
    }

    /// One HAL output unit + mix buffers for a destination.
    final class OutputBusContext: @unchecked Sendable {
        let destinationKey: String
        let shared: SharedMixState
        let isPrimary: Bool
        var mixLeft: UnsafeMutablePointer<Float>
        var mixRight: UnsafeMutablePointer<Float>
        var tmpLeft: UnsafeMutablePointer<Float>
        var tmpRight: UnsafeMutablePointer<Float>
        /// Accumulates streams that use the shared global EQ (processed once per buffer).
        var globalLeft: UnsafeMutablePointer<Float>
        var globalRight: UnsafeMutablePointer<Float>
        let maxFrames: Int
        var capturePrimed = false
        var outputCallbacks: UInt64 = 0
        var spectrumStride: UInt32 = 0
        var unit: AudioComponentInstance?
        var deviceID: AudioObjectID = kAudioObjectUnknown

        init(destinationKey: String, shared: SharedMixState, isPrimary: Bool) {
            self.destinationKey = destinationKey
            self.shared = shared
            self.isPrimary = isPrimary
            self.maxFrames = shared.maxFrames
            self.mixLeft = .allocate(capacity: shared.maxFrames)
            self.mixRight = .allocate(capacity: shared.maxFrames)
            self.tmpLeft = .allocate(capacity: shared.maxFrames)
            self.tmpRight = .allocate(capacity: shared.maxFrames)
            self.globalLeft = .allocate(capacity: shared.maxFrames)
            self.globalRight = .allocate(capacity: shared.maxFrames)
            mixLeft.initialize(repeating: 0, count: shared.maxFrames)
            mixRight.initialize(repeating: 0, count: shared.maxFrames)
            tmpLeft.initialize(repeating: 0, count: shared.maxFrames)
            tmpRight.initialize(repeating: 0, count: shared.maxFrames)
            globalLeft.initialize(repeating: 0, count: shared.maxFrames)
            globalRight.initialize(repeating: 0, count: shared.maxFrames)
        }

        deinit {
            mixLeft.deallocate()
            mixRight.deallocate()
            tmpLeft.deallocate()
            tmpRight.deallocate()
            globalLeft.deallocate()
            globalRight.deallocate()
        }
    }

    public init() {
        selectedInputDeviceID = devices.selectedInputID
        selectedOutputDeviceID = devices.selectedOutputID
        inputDeviceName = devices.inputName()
        outputDeviceName = devices.outputName()
        installDefaultOutputListener()
        installDeviceListListener()
    }

    // MARK: - Public

    /// Start routing for the given app clusters (each card PID gets its own process tap + volume/balance).
    public func startSystemRouting(routedClusters: [ProcessTapIO.TapCluster]) {
        guard !isStarting else { return }

        if isRouting, sharedMix != nil, !outputBuses.isEmpty {
            do {
                try updateSystemRouting(routedClusters: routedClusters)
                return
            } catch {
                log.error("differential update failed, full restart: \(error.localizedDescription, privacy: .public)")
            }
        }

        isStarting = true
        suppressDeviceRestart = true
        defer {
            isStarting = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.suppressDeviceRestart = false
            }
        }

        stopSystemRouting()

        guard #available(macOS 14.2, *) else {
            state = .error("Process taps require macOS 14.2+")
            return
        }

        do {
            let handles = try processTaps.startAppTaps(clusters: routedClusters)
            try configureGraph(appTaps: handles)
            syncPreAmpFromEQ()
            state = .running
            isRouting = true
            activeStreamCount = handles.count
            lastIOError = nil
            startIOStatusPoll()
            refreshActiveOutputSummary()
            log.info("routing \(handles.count) app streams → \(self.outputBuses.count) outputs")
        } catch {
            stopSystemRouting()
            state = .error(error.localizedDescription)
            isRouting = false
            log.error("start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func startSystemRouting(routedPIDs: [pid_t] = []) {
        startSystemRouting(routedClusters: routedPIDs.map {
            ProcessTapIO.TapCluster(keyPID: $0, audioPIDs: [$0])
        })
    }

    @available(macOS 14.2, *)
    private func updateSystemRouting(routedClusters: [ProcessTapIO.TapCluster]) throws {
        guard let shared = sharedMix else {
            throw NSError(domain: "OmniLevel", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Graph not ready for differential update"
            ])
        }

        let desired = Set(routedClusters.map(\.keyPID))
        let current = Set(streamContexts.map(\.pid))
        let handles = try processTaps.syncAppTaps(clusters: routedClusters)
        let handleByPID = Dictionary(uniqueKeysWithValues: handles.map { ($0.pid, $0) })
        let liveKeys = Set(handles.map(\.pid))

        let rate = sampleRate > 0 ? sampleRate : ProcessTapIO.deviceSampleRate(preferredOutputDeviceID())
        let bufferFrames: UInt32 = 512
        let asbd = Self.stereoFloatNonInterleavedASBD(sampleRate: rate)
        let ringCap = Int(max(rate, 48_000) * 0.35)

        var nextStreams = streamContexts
        let removed = nextStreams.filter { !liveKeys.contains($0.pid) }
        for stream in removed {
            if let unit = stream.unit {
                AudioOutputUnitStop(unit)
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
            }
            stream.unit = nil
            stream.ring.reset()
            mixer.removeStream(stream.pid)
            // Keep EQ override DSP warm — app may re-route (solo / On-Off) shortly.
        }
        nextStreams.removeAll { !liveKeys.contains($0.pid) }

        let existing = Set(nextStreams.map(\.pid))
        for pid in liveKeys.sorted() where !existing.contains(pid) {
            guard let handle = handleByPID[pid] else { continue }
            Self.trySetSampleRate(handle.aggregateDeviceID, rate: rate)
            Self.trySetBufferFrames(handle.aggregateDeviceID, frames: bufferFrames)

            let stream = StreamContext(pid: handle.pid, ringCapacity: ringCap)
            stream.destinationKey = normalizedDestinationKey(streamRouteProvider?(handle.pid))
            let unit = try makeHALUnit()
            try setEnableIO(unit, input: true, output: false)
            try setCurrentDevice(unit, handle.aggregateDeviceID)
            try setMaxFrames(unit, frames: UInt32(stream.maxFrames))
            try setStreamFormat(unit, scope: kAudioUnitScope_Output, element: 1, asbd: asbd)

            stream.unit = unit
            let refCon = Unmanaged.passUnretained(stream).toOpaque()
            var inputCB = AURenderCallbackStruct(inputProc: streamInputCallback, inputProcRefCon: refCon)
            try OSStatusCheck(
                AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_SetInputCallback,
                    kAudioUnitScope_Global,
                    0,
                    &inputCB,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                ),
                "SetInputCallback pid=\(handle.pid)"
            )
            try OSStatusCheck(AudioUnitInitialize(unit), "Init input pid=\(handle.pid)")
            try OSStatusCheck(AudioOutputUnitStart(unit), "Start input pid=\(handle.pid)")
            nextStreams.append(stream)
        }

        // Refresh destinations on surviving streams.
        for stream in nextStreams {
            stream.destinationKey = normalizedDestinationKey(streamRouteProvider?(stream.pid))
        }

        streamContexts = nextStreams
        shared.setStreams(nextStreams)
        try syncOutputBuses(shared: shared, asbd: asbd)

        activeStreamCount = nextStreams.count
        isRouting = true
        state = .running
        lastIOError = nil
        refreshActiveOutputSummary()
        log.info("hot-updated route → \(nextStreams.count) streams / \(self.outputBuses.count) outputs (desired=\(desired.count) currentWas=\(current.count))")
    }

    public func startSystemRouting(excludePIDs: [pid_t]) {
        startSystemRouting(routedClusters: currentRoutedClusters())
        _ = excludePIDs
    }

    public func stopSystemRouting() {
        stopIOStatusPoll()
        teardownUnits()
        processTaps.destroyAllAppTaps()
        sharedMix = nil
        streamContexts = []
        activeStreamCount = 0
        isRouting = false
        activeOutputSummary = ""
        if case .error = state {} else { state = .stopped }
    }

    public func start() {
        startSystemRouting(routedClusters: currentRoutedClusters())
    }

    public func stop(preserveRing: Bool = false) { stopSystemRouting() }

    public func syncPreAmpFromEQ() {
        let db = equalizer.isAutoPreAmpEnabled() ? equalizer.currentAutoPreAmpdB() : 0
        limiter.setPreAmpdB(db)
    }

    public func selectOutputDevice(_ id: AudioObjectID) {
        devices.selectedOutputID = id
        selectedOutputDeviceID = id
        outputDeviceName = devices.outputName()
        if isRouting {
            startSystemRouting(routedClusters: currentRoutedClusters())
        }
    }

    public func selectInputDevice(_ id: AudioObjectID) {
        devices.selectedInputID = id
        selectedInputDeviceID = id
        inputDeviceName = devices.inputName()
    }

    public func refreshDevices() {
        devices.refresh()
        selectedInputDeviceID = devices.selectedInputID
        selectedOutputDeviceID = devices.selectedOutputID
        inputDeviceName = devices.inputName()
        outputDeviceName = devices.outputName()
    }

    /// Resolve a stored device UID to a live AudioObjectID. Falls back to System Default when missing.
    public func resolveOutputDevice(uid: String?, refresh: Bool = false) -> (id: AudioObjectID, fallback: Bool, key: String) {
        if refresh { devices.refresh() }
        let key = normalizedDestinationKey(uid)
        if key == Self.systemDefaultDestinationKey {
            return (preferredOutputDeviceID(), false, key)
        }
        if let match = devices.outputDevices.first(where: { $0.uid == key }) {
            return (match.id, false, key)
        }
        return (preferredOutputDeviceID(), true, Self.systemDefaultDestinationKey)
    }

    // MARK: - Per-stream EQ overrides

    public func setStreamEQOverride(pid: pid_t, gains: [Float], qFactors: [Float]? = nil) {
        guard gains.count == EqualizerDSP.bandCount else { return }
        let dsp: EqualizerDSP
        if let existing = eqOverrideTable.get(pid) {
            dsp = existing
        } else {
            let created = EqualizerDSP()
            created.setSampleRate(sampleRate > 0 ? sampleRate : 48_000)
            eqOverrideTable.set(pid, dsp: created)
            dsp = created
        }
        dsp.applyGains(gains, qFactors: qFactors)
        publishOverrides()
    }

    public func clearStreamEQOverride(pid: pid_t) {
        removeEQOverride(pid: pid)
        publishOverrides()
    }

    public func clearAllEQOverrides() {
        eqOverrideTable.removeAll()
        publishOverrides()
    }

    public func hasEQOverride(pid: pid_t) -> Bool {
        eqOverrideTable.get(pid) != nil
    }

    /// Per-stream peak levels in dBFS for UI meters / silent-app filtering.
    public func snapshotPeakLevels() -> [pid_t: Float] {
        var result: [pid_t: Float] = [:]
        for stream in streamContexts {
            result[stream.pid] = stream.peakLeveldB()
        }
        return result
    }

    /// Drive per-app EQ meters from a single stream (`nil` clears focus).
    public func setSpectrumFocusPID(_ pid: pid_t?) {
        let value = pid ?? 0
        spectrumFocusLock.withLock { $0 = value }
        sharedMix?.setFocusPID(value)
    }

    private func removeEQOverride(pid: pid_t) {
        eqOverrideTable.remove(pid)
    }

    private func publishOverrides() {
        let snapshot = eqOverrideTable.snapshot()
        sharedMix?.setOverrides(snapshot)
        eqOverrideCount = snapshot.count
    }

    /// Returns which app clusters should be under OmniLevel control with their own tap.
    var routedClustersProvider: (() -> [ProcessTapIO.TapCluster])?
    /// Per-stream output UID (`nil` = System Default).
    var streamRouteProvider: ((pid_t) -> String?)?

    private func currentRoutedClusters() -> [ProcessTapIO.TapCluster] {
        if let provider = routedClustersProvider {
            return provider()
        }
        return []
    }

    private func normalizedDestinationKey(_ uid: String?) -> String {
        guard let uid else { return Self.systemDefaultDestinationKey }
        let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.systemDefaultDestinationKey : trimmed
    }

    // MARK: - Graph

    private func preferredOutputDeviceID() -> AudioObjectID {
        var id = devices.selectedOutputID
        if id == kAudioObjectUnknown {
            devices.refresh()
            id = devices.selectedOutputID
        }
        if id == kAudioObjectUnknown { id = ProcessTapIO.defaultOutputDeviceID() }
        return id
    }

    private func configureGraph(appTaps: [ProcessTapIO.AppTapHandle]) throws {
        let outputID = preferredOutputDeviceID()
        selectedOutputDeviceID = outputID
        outputDeviceName = Self.deviceName(outputID) ?? "Default Output"

        let rate = ProcessTapIO.deviceSampleRate(outputID)
        sampleRate = rate
        equalizer.setSampleRate(rate)
        limiter.setSampleRate(rate)
        eqOverrideTable.forEachDSP { $0.setSampleRate(rate) }

        let bufferFrames: UInt32 = 512
        Self.trySetBufferFrames(outputID, frames: bufferFrames)
        Self.trySetSampleRate(outputID, rate: rate)

        let asbd = Self.stereoFloatNonInterleavedASBD(sampleRate: rate)
        let ringCap = Int(rate * 0.35)

        var streams: [StreamContext] = []
        for handle in appTaps {
            Self.trySetSampleRate(handle.aggregateDeviceID, rate: rate)
            Self.trySetBufferFrames(handle.aggregateDeviceID, frames: bufferFrames)

            let stream = StreamContext(pid: handle.pid, ringCapacity: ringCap)
            stream.destinationKey = normalizedDestinationKey(streamRouteProvider?(handle.pid))
            let unit = try makeHALUnit()
            try setEnableIO(unit, input: true, output: false)
            try setCurrentDevice(unit, handle.aggregateDeviceID)
            try setMaxFrames(unit, frames: UInt32(stream.maxFrames))
            try setStreamFormat(unit, scope: kAudioUnitScope_Output, element: 1, asbd: asbd)

            stream.unit = unit
            let refCon = Unmanaged.passUnretained(stream).toOpaque()
            var inputCB = AURenderCallbackStruct(inputProc: streamInputCallback, inputProcRefCon: refCon)
            try OSStatusCheck(
                AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_SetInputCallback,
                    kAudioUnitScope_Global,
                    0,
                    &inputCB,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                ),
                "SetInputCallback pid=\(handle.pid)"
            )
            try OSStatusCheck(AudioUnitInitialize(unit), "Init input pid=\(handle.pid)")
            streams.append(stream)
        }

        streamContexts = streams
        let overrides = eqOverrideTable.snapshot()
        let focusPID = spectrumFocusLock.withLock { $0 }
        let shared = SharedMixState(
            equalizer: equalizer,
            limiter: limiter,
            levels: levels,
            spectrum: spectrum,
            spectrumInput: spectrumInput,
            focusedSpectrum: focusedSpectrum,
            focusedSpectrumInput: focusedSpectrumInput,
            mixer: mixer,
            streams: streams,
            overrides: overrides,
            focusPID: focusPID
        )
        sharedMix = shared

        try syncOutputBuses(shared: shared, asbd: asbd)

        for stream in streams {
            if let unit = stream.unit {
                try OSStatusCheck(AudioOutputUnitStart(unit), "Start input pid=\(stream.pid)")
            }
        }

        for bus in outputBuses.values {
            bus.capturePrimed = false
            if let unit = bus.unit {
                try OSStatusCheck(AudioOutputUnitStart(unit), "Start output \(bus.destinationKey)")
            }
            let weakBus = bus
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
                weakBus.capturePrimed = true
            }
        }
    }

    /// Ensure one output bus exists per destination currently used by streams.
    private func syncOutputBuses(
        shared: SharedMixState,
        asbd: AudioStreamBasicDescription
    ) throws {
        // Resolve missing UIDs onto System Default before grouping.
        for stream in streamContexts {
            let key = stream.destinationKey
            if key == Self.systemDefaultDestinationKey { continue }
            let resolved = resolveOutputDevice(uid: key)
            if resolved.fallback {
                stream.destinationKey = Self.systemDefaultDestinationKey
            }
        }

        var needed = Set(streamContexts.map(\.destinationKey))
        if needed.isEmpty {
            needed.insert(Self.systemDefaultDestinationKey)
        }

        // Tear down unused buses.
        for key in outputBuses.keys where !needed.contains(key) {
            if let bus = outputBuses.removeValue(forKey: key), let unit = bus.unit {
                AudioOutputUnitStop(unit)
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
                bus.unit = nil
            }
        }

        for key in needed {
            let resolved = resolveOutputDevice(uid: key.isEmpty ? nil : key)
            let deviceID = resolved.id

            if let existing = outputBuses[key] {
                if existing.deviceID != deviceID {
                    if let unit = existing.unit {
                        AudioOutputUnitStop(unit)
                        AudioUnitUninitialize(unit)
                        AudioComponentInstanceDispose(unit)
                    }
                    existing.unit = nil
                    try attachOutputUnit(to: existing, deviceID: deviceID, asbd: asbd)
                    existing.deviceID = deviceID
                    if let unit = existing.unit {
                        try OSStatusCheck(AudioOutputUnitStart(unit), "Restart output \(key)")
                    }
                    existing.capturePrimed = true
                }
                continue
            }

            let isPrimary = key == Self.systemDefaultDestinationKey
            let bus = OutputBusContext(destinationKey: key, shared: shared, isPrimary: isPrimary)
            try attachOutputUnit(to: bus, deviceID: deviceID, asbd: asbd)
            bus.deviceID = deviceID
            outputBuses[key] = bus
            if isRouting, let unit = bus.unit {
                try OSStatusCheck(AudioOutputUnitStart(unit), "Start output \(key)")
                bus.capturePrimed = true
            }
        }

        shared.setStreams(streamContexts)
        refreshActiveOutputSummary()
    }

    private func attachOutputUnit(
        to bus: OutputBusContext,
        deviceID: AudioObjectID,
        asbd: AudioStreamBasicDescription
    ) throws {
        Self.trySetSampleRate(deviceID, rate: sampleRate)
        Self.trySetBufferFrames(deviceID, frames: 512)

        let outUnit = try makeHALUnit()
        try setEnableIO(outUnit, input: false, output: true)
        try setCurrentDevice(outUnit, deviceID)
        try setMaxFrames(outUnit, frames: UInt32(bus.maxFrames))
        try setStreamFormat(outUnit, scope: kAudioUnitScope_Input, element: 0, asbd: asbd)

        let ref = Unmanaged.passUnretained(bus).toOpaque()
        var outputCB = AURenderCallbackStruct(inputProc: mixOutputCallback, inputProcRefCon: ref)
        try OSStatusCheck(
            AudioUnitSetProperty(
                outUnit,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &outputCB,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            "SetRenderCallback"
        )
        try OSStatusCheck(AudioUnitInitialize(outUnit), "Initialize output unit")
        bus.unit = outUnit
    }

    private func teardownUnits() {
        for bus in outputBuses.values {
            if let unit = bus.unit {
                AudioOutputUnitStop(unit)
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
            }
            bus.unit = nil
        }
        outputBuses.removeAll()

        for stream in streamContexts {
            if let unit = stream.unit {
                AudioOutputUnitStop(unit)
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
            }
            stream.unit = nil
            stream.ring.reset()
        }
        streamContexts = []
    }

    private func refreshActiveOutputSummary() {
        if outputBuses.isEmpty {
            activeOutputSummary = outputDeviceName
            return
        }
        let names: [String] = outputBuses.keys.sorted().map { key in
            if key == Self.systemDefaultDestinationKey {
                return outputDeviceName
            }
            return devices.outputDevices.first(where: { $0.uid == key })?.name ?? key
        }
        // Unique while preserving order
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        activeOutputSummary = unique.joined(separator: " · ")
    }

    private func startIOStatusPoll() {
        stopIOStatusPoll()
        ioStatusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let shared = self.sharedMix else { return }
                let streams = shared.streams
                let totalCB = streams.reduce(UInt64(0)) { $0 + $1.callbacks }
                let failing = streams.filter { $0.lastStatus != noErr }.count
                let live = streams.filter { $0.framesWithSignal > 0 }.count
                let outCB = self.outputBuses.values.reduce(UInt64(0)) { $0 + $1.outputCallbacks }
                let next: String?
                if streams.isEmpty {
                    next = "No app taps"
                } else if totalCB == 0 {
                    next = "No capture callbacks"
                } else if failing == streams.count, streams.count > 0 {
                    next = "All captures failing (\(streams.first?.lastStatus ?? 0))"
                } else if live == 0, outCB > 80 {
                    next = "Taps silent (play audio in an On app)"
                } else {
                    next = nil
                }
                if self.lastIOError != next {
                    self.lastIOError = next
                }
            }
        }
    }

    private func stopIOStatusPoll() {
        ioStatusTimer?.invalidate()
        ioStatusTimer = nil
    }

    // MARK: - HAL helpers

    private func makeHALUnit() throws -> AudioComponentInstance {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw NSError(domain: "OmniLevel", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "HAL Output component not found"
            ])
        }
        var unit: AudioComponentInstance?
        let status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else {
            throw NSError(domain: "OmniLevel", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "AudioComponentInstanceNew failed (\(status))"
            ])
        }
        return unit
    }

    private func setEnableIO(_ unit: AudioComponentInstance, input: Bool, output: Bool) throws {
        var inEnable: UInt32 = input ? 1 : 0
        try OSStatusCheck(
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &inEnable, UInt32(MemoryLayout<UInt32>.size)),
            "EnableIO input"
        )
        var outEnable: UInt32 = output ? 1 : 0
        try OSStatusCheck(
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &outEnable, UInt32(MemoryLayout<UInt32>.size)),
            "EnableIO output"
        )
    }

    private func setCurrentDevice(_ unit: AudioComponentInstance, _ deviceID: AudioObjectID) throws {
        var device = deviceID
        try OSStatusCheck(
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioObjectID>.size)),
            "SetCurrentDevice"
        )
    }

    private func setMaxFrames(_ unit: AudioComponentInstance, frames: UInt32) throws {
        var f = frames
        try OSStatusCheck(
            AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &f, UInt32(MemoryLayout<UInt32>.size)),
            "MaximumFramesPerSlice"
        )
    }

    private func setStreamFormat(
        _ unit: AudioComponentInstance,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        asbd: AudioStreamBasicDescription
    ) throws {
        var format = asbd
        try OSStatusCheck(
            AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, element, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
            "StreamFormat"
        )
    }

    private static func stereoFloatNonInterleavedASBD(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private static func trySetSampleRate(_ deviceID: AudioObjectID, rate: Double) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Float64(rate)
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
    }

    private static func trySetBufferFrames(_ deviceID: AudioObjectID, frames: UInt32) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = frames
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private static func deviceName(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let name else { return nil }
        return name as String
    }

    private func installDefaultOutputListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, !self.suppressDeviceRestart else { return }
                self.debounceWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isRouting, !self.suppressDeviceRestart else { return }
                    self.refreshDevices()
                    self.startSystemRouting(routedClusters: self.currentRoutedClusters())
                }
                self.debounceWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated),
            block
        )
    }

    private func installDeviceListListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, !self.suppressDeviceRestart else { return }
                self.debounceWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.refreshDevices()
                    NotificationCenter.default.post(name: .omniLevelOutputDevicesDidChange, object: nil)
                    guard self.isRouting, !self.suppressDeviceRestart else { return }
                    self.startSystemRouting(routedClusters: self.currentRoutedClusters())
                }
                self.debounceWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated),
            block
        )
    }

    func beginSuppressingDeviceRestarts() { suppressDeviceRestart = true }
    func endSuppressingDeviceRestarts() { suppressDeviceRestart = false }
    var suppressGraphResetNotification = false
}

// MARK: - Per-app capture (TN2091)

private func streamInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let stream = Unmanaged<AudioEngineController.StreamContext>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let unit = stream.unit else { return noErr }

    let frames = Int(inNumberFrames)
    guard frames > 0, frames <= stream.maxFrames else { return noErr }

    stream.callbacks &+= 1
    let byteSize = UInt32(frames * MemoryLayout<Float>.size)
    stream.pullABL.unsafeMutablePointer.pointee.mNumberBuffers = 2
    stream.pullABL[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize, mData: UnsafeMutableRawPointer(stream.left))
    stream.pullABL[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize, mData: UnsafeMutableRawPointer(stream.right))

    let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, stream.pullABL.unsafeMutablePointer)
    stream.lastStatus = status
    guard status == noErr else { return status }

    var peak: Float = 0
    vDSP_maxmgv(stream.left, 1, &peak, vDSP_Length(frames))
    if peak > 1e-6 { stream.framesWithSignal &+= UInt64(frames) }
    stream.noteMeterSamples(left: stream.left, right: stream.right, count: frames)

    stream.ring.write(left: stream.left, right: stream.right, count: frames)
    return noErr
}

// MARK: - Per-destination mix + per-stream EQ

private func mixOutputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData else { return noErr }
    let bus = Unmanaged<AudioEngineController.OutputBusContext>.fromOpaque(inRefCon).takeUnretainedValue()
    let ctx = bus.shared
    bus.outputCallbacks &+= 1

    let frames = Int(inNumberFrames)
    guard frames > 0, frames <= bus.maxFrames else {
        zeroABL(ioData)
        return noErr
    }

    if !bus.capturePrimed {
        zeroABL(ioData)
        return noErr
    }

    memset(bus.mixLeft, 0, frames * 4)
    memset(bus.mixRight, 0, frames * 4)
    memset(bus.globalLeft, 0, frames * 4)
    memset(bus.globalRight, 0, frames * 4)

    let focusPID = ctx.focusPID
    var fedFocus = false
    bus.spectrumStride &+= 1
    let meterThisBlock = (bus.spectrumStride & 3) == 0

    // Per stream: gain/pan, then either dedicated override EQ or accumulate for one global EQ pass.
    for stream in ctx.streams where stream.destinationKey == bus.destinationKey {
        let got = stream.ring.read(left: bus.tmpLeft, right: bus.tmpRight, count: frames)
        guard got > 0 else { continue }
        // Only process real samples — do not EQ/mix the zero-padded underrun tail.
        let n = got

        // Meter from the mix pull (authoritative — always runs when audio is routed).
        stream.noteMeterSamples(left: bus.tmpLeft, right: bus.tmpRight, count: n)

        ctx.mixer.applyStereo(
            pid: stream.pid,
            left: bus.tmpLeft,
            right: bus.tmpRight,
            frameCount: n
        )

        let isFocus = focusPID != 0 && stream.pid == focusPID
        if isFocus, meterThisBlock {
            ctx.focusedSpectrumInput.push(samples: bus.tmpLeft, count: n)
            fedFocus = true
        }

        if let overrideEQ = ctx.overrideEqualizer(for: stream.pid) {
            overrideEQ.processChannels(left: bus.tmpLeft, right: bus.tmpRight, frameCount: n)
            if isFocus, meterThisBlock {
                ctx.focusedSpectrum.push(samples: bus.tmpLeft, count: n)
            }
            vDSP_vadd(bus.mixLeft, 1, bus.tmpLeft, 1, bus.mixLeft, 1, vDSP_Length(n))
            vDSP_vadd(bus.mixRight, 1, bus.tmpRight, 1, bus.mixRight, 1, vDSP_Length(n))
        } else {
            vDSP_vadd(bus.globalLeft, 1, bus.tmpLeft, 1, bus.globalLeft, 1, vDSP_Length(n))
            vDSP_vadd(bus.globalRight, 1, bus.tmpRight, 1, bus.globalRight, 1, vDSP_Length(n))
        }
    }

    // Focused app silent → meters decay to empty (don't show other apps' energy).
    if focusPID != 0, !fedFocus, meterThisBlock {
        memset(bus.tmpLeft, 0, frames * 4)
        ctx.focusedSpectrumInput.push(samples: bus.tmpLeft, count: frames)
        ctx.focusedSpectrum.push(samples: bus.tmpLeft, count: frames)
    }

    // Global EQ meters: capture dry bus *before* EQ, then process, then full mix for visualizer.
    if bus.isPrimary, meterThisBlock {
        var half: Float = 0.5
        vDSP_vasm(bus.globalLeft, 1, bus.globalRight, 1, &half, bus.tmpLeft, 1, vDSP_Length(frames))
        ctx.spectrumInput.push(samples: bus.tmpLeft, count: frames)
    }

    ctx.equalizer.processChannels(left: bus.globalLeft, right: bus.globalRight, frameCount: frames)
    vDSP_vadd(bus.mixLeft, 1, bus.globalLeft, 1, bus.mixLeft, 1, vDSP_Length(frames))
    vDSP_vadd(bus.mixRight, 1, bus.globalRight, 1, bus.mixRight, 1, vDSP_Length(frames))

    ctx.limiter.process(left: bus.mixLeft, right: bus.mixRight, frameCount: frames)

    if bus.isPrimary {
        ctx.levels.process(left: bus.mixLeft, right: bus.mixRight, frameCount: frames)
        if meterThisBlock {
            // Post-EQ / post-mix (and limiter) — EQ fader “out” + Monitor visualizer.
            ctx.spectrum.push(samples: bus.mixLeft, count: frames)
        }
    }

    let byteSize = UInt32(frames * 4)
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    if abl.count >= 2 {
        if let p = abl[0].mData?.assumingMemoryBound(to: Float.self) {
            memcpy(p, bus.mixLeft, frames * 4)
            abl[0].mDataByteSize = byteSize
        }
        if let p = abl[1].mData?.assumingMemoryBound(to: Float.self) {
            memcpy(p, bus.mixRight, frames * 4)
            abl[1].mDataByteSize = byteSize
        }
    } else if abl.count == 1, let p = abl[0].mData?.assumingMemoryBound(to: Float.self) {
        let ch = max(Int(abl[0].mNumberChannels), 1)
        if ch == 1 {
            for i in 0..<frames { p[i] = 0.5 * (bus.mixLeft[i] + bus.mixRight[i]) }
        } else {
            for i in 0..<frames {
                p[i * ch] = bus.mixLeft[i]
                p[i * ch + 1] = bus.mixRight[i]
            }
        }
        abl[0].mDataByteSize = UInt32(frames * ch * 4)
    }
    return noErr
}

private func zeroABL(_ ioData: UnsafeMutablePointer<AudioBufferList>) {
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    for buf in abl {
        if let p = buf.mData, buf.mDataByteSize > 0 {
            memset(p, 0, Int(buf.mDataByteSize))
        }
    }
}

private func OSStatusCheck(_ status: OSStatus, _ label: String) throws {
    guard status == noErr else {
        throw NSError(domain: "OmniLevel", code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "\(label) failed (OSStatus \(status))"
        ])
    }
}

extension Notification.Name {
    static let omniLevelEngineGraphDidReset = Notification.Name("omniLevelEngineGraphDidReset")
    static let omniLevelOutputDevicesDidChange = Notification.Name("omniLevelOutputDevicesDidChange")
}
