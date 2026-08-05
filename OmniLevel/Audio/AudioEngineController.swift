import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Per-app process-tap capture (TN2091 input callback each) → gain/balance mix → EQ → speakers.
@MainActor
public final class AudioEngineController: ObservableObject {
    public enum EngineState: Equatable {
        case stopped
        case running
        case error(String)
    }

    @Published public private(set) var state: EngineState = .stopped
    @Published public private(set) var sampleRate: Double = 48_000
    @Published public private(set) var outputDeviceName: String = "Default"
    @Published public private(set) var inputDeviceName: String = "Default"
    @Published public private(set) var selectedOutputDeviceID: AudioObjectID = kAudioObjectUnknown
    @Published public private(set) var selectedInputDeviceID: AudioObjectID = kAudioObjectUnknown
    @Published public private(set) var isRouting = false
    @Published public private(set) var lastIOError: String?
    @Published public private(set) var activeStreamCount: Int = 0

    public let equalizer = EqualizerDSP()
    public let limiter = AutoPreAmpLimiter()
    public let mixer = GainPanMixer()
    public let levels = AudioLevels()
    /// Post-EQ / post-mix spectrum (what you hear).
    public let spectrum = SpectrumAnalyzer()
    /// Pre-EQ mix bus spectrum (material before the equalizer).
    public let spectrumInput = SpectrumAnalyzer()
    public let processTaps = ProcessTapIO()
    public let devices = AudioDeviceManager()

    private var mixContext: MixContext?
    private var streamContexts: [StreamContext] = []
    private var outputUnit: AudioComponentInstance?
    private var debounceWorkItem: DispatchWorkItem?
    private var suppressDeviceRestart = false
    private var isStarting = false
    private var ioStatusTimer: Timer?
    private let log = Logger(subsystem: "com.omnilevel.app", category: "engine")

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

        deinit {
            left.deallocate()
            right.deallocate()
            free(pullABL.unsafeMutablePointer)
        }
    }

    /// Shared mix / EQ state for the output callback.
    final class MixContext: @unchecked Sendable {
        let equalizer: EqualizerDSP
        let limiter: AutoPreAmpLimiter
        let levels: AudioLevels
        let spectrum: SpectrumAnalyzer
        let spectrumInput: SpectrumAnalyzer
        let mixer: GainPanMixer
        /// Live stream list — swapped under lock so routes can hot-add/remove without stopping output.
        private let streamsLock = OSAllocatedUnfairLock()
        private var streamsStorage: [StreamContext]
        var mixLeft: UnsafeMutablePointer<Float>
        var mixRight: UnsafeMutablePointer<Float>
        var tmpLeft: UnsafeMutablePointer<Float>
        var tmpRight: UnsafeMutablePointer<Float>
        let maxFrames: Int
        var capturePrimed = false
        var outputCallbacks: UInt64 = 0
        var spectrumStride: UInt32 = 0

        init(
            equalizer: EqualizerDSP,
            limiter: AutoPreAmpLimiter,
            levels: AudioLevels,
            spectrum: SpectrumAnalyzer,
            spectrumInput: SpectrumAnalyzer,
            mixer: GainPanMixer,
            streams: [StreamContext],
            maxFrames: Int = 4_096
        ) {
            self.equalizer = equalizer
            self.limiter = limiter
            self.levels = levels
            self.spectrum = spectrum
            self.spectrumInput = spectrumInput
            self.mixer = mixer
            self.streamsStorage = streams
            self.maxFrames = maxFrames
            self.mixLeft = .allocate(capacity: maxFrames)
            self.mixRight = .allocate(capacity: maxFrames)
            self.tmpLeft = .allocate(capacity: maxFrames)
            self.tmpRight = .allocate(capacity: maxFrames)
            mixLeft.initialize(repeating: 0, count: maxFrames)
            mixRight.initialize(repeating: 0, count: maxFrames)
            tmpLeft.initialize(repeating: 0, count: maxFrames)
            tmpRight.initialize(repeating: 0, count: maxFrames)
        }

        var streams: [StreamContext] {
            streamsLock.withLock { streamsStorage }
        }

        func setStreams(_ next: [StreamContext]) {
            streamsLock.withLock { streamsStorage = next }
        }

        deinit {
            mixLeft.deallocate()
            mixRight.deallocate()
            tmpLeft.deallocate()
            tmpRight.deallocate()
        }
    }

    public init() {
        selectedInputDeviceID = devices.selectedInputID
        selectedOutputDeviceID = devices.selectedOutputID
        inputDeviceName = devices.inputName()
        outputDeviceName = devices.outputName()
        installDefaultOutputListener()
    }

    // MARK: - Public

    /// Start routing for the given app PIDs (each gets its own process tap + volume/balance).
    /// Uses a seamless differential update when already routing so open/close of apps
    /// does not tear down living streams.
    public func startSystemRouting(routedPIDs: [pid_t] = []) {
        guard !isStarting else { return }

        // Hot path: differential add/remove — keep output unit + surviving taps alive.
        if isRouting, mixContext != nil, outputUnit != nil {
            do {
                try updateSystemRouting(routedPIDs: routedPIDs)
                return
            } catch {
                log.error("differential update failed, full restart: \(error.localizedDescription, privacy: .public)")
                // Fall through to full rebuild.
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
            let outputID = preferredOutputDeviceID()
            let handles = try processTaps.startAppTaps(pids: routedPIDs)
            try configureGraph(appTaps: handles, outputDeviceID: outputID)
            syncPreAmpFromEQ()
            state = .running
            isRouting = true
            activeStreamCount = handles.count
            lastIOError = nil
            startIOStatusPoll()
            log.info("routing \(handles.count) app streams → out=\(outputID)")
        } catch {
            stopSystemRouting()
            state = .error(error.localizedDescription)
            isRouting = false
            log.error("start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Add/remove process taps and capture streams without stopping the shared output unit.
    @available(macOS 14.2, *)
    private func updateSystemRouting(routedPIDs: [pid_t]) throws {
        guard let mix = mixContext, outputUnit != nil else {
            throw NSError(domain: "OmniLevel", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Graph not ready for differential update"
            ])
        }

        let desired = Set(routedPIDs)
        let current = Set(streamContexts.map(\.pid))
        if desired == current {
            activeStreamCount = streamContexts.count
            isRouting = true
            state = .running
            return
        }

        let handles = try processTaps.syncAppTaps(pids: routedPIDs)
        let handleByPID = Dictionary(uniqueKeysWithValues: handles.map { ($0.pid, $0) })

        let rate = sampleRate > 0 ? sampleRate : ProcessTapIO.deviceSampleRate(preferredOutputDeviceID())
        let bufferFrames: UInt32 = 512
        let asbd = Self.stereoFloatNonInterleavedASBD(sampleRate: rate)
        let ringCap = Int(max(rate, 48_000) * 0.35)

        // Remove streams no longer desired
        var nextStreams = streamContexts
        let removed = nextStreams.filter { !desired.contains($0.pid) }
        for stream in removed {
            if let unit = stream.unit {
                AudioOutputUnitStop(unit)
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
            }
            stream.unit = nil
            stream.ring.reset()
            mixer.removeStream(stream.pid)
        }
        nextStreams.removeAll { !desired.contains($0.pid) }

        // Add new streams
        let existing = Set(nextStreams.map(\.pid))
        for pid in desired where !existing.contains(pid) {
            guard let handle = handleByPID[pid] else { continue }
            Self.trySetSampleRate(handle.aggregateDeviceID, rate: rate)
            Self.trySetBufferFrames(handle.aggregateDeviceID, frames: bufferFrames)

            let stream = StreamContext(pid: handle.pid, ringCapacity: ringCap)
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

        // Publish on both controller + live mix callback — no silence, no output restart.
        streamContexts = nextStreams
        mix.setStreams(nextStreams)
        activeStreamCount = nextStreams.count
        isRouting = true
        state = .running
        lastIOError = nil
        log.info("hot-updated route → \(nextStreams.count) streams (added \(desired.subtracting(current).count), removed \(current.subtracting(desired).count))")
    }

    /// Compatibility: provider may still hand exclude list; prefer routedPIDsProvider.
    public func startSystemRouting(excludePIDs: [pid_t]) {
        // Legacy signature — derive routed from provider if available.
        if let provider = routedPIDsProvider {
            startSystemRouting(routedPIDs: provider())
        } else {
            startSystemRouting(routedPIDs: [])
        }
        _ = excludePIDs
    }

    public func stopSystemRouting() {
        stopIOStatusPoll()
        teardownUnits()
        processTaps.destroyAllAppTaps()
        mixContext = nil
        streamContexts = []
        activeStreamCount = 0
        isRouting = false
        if case .error = state {} else { state = .stopped }
    }

    public func start() {
        startSystemRouting(routedPIDs: routedPIDsProvider?() ?? [])
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
            startSystemRouting(routedPIDs: routedPIDsProvider?() ?? [])
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

    /// Returns which PIDs should be under OmniLevel control with their own tap.
    var routedPIDsProvider: (() -> [pid_t])?

    // MARK: - Graph

    private func preferredOutputDeviceID() -> AudioObjectID {
        devices.refresh()
        var id = devices.selectedOutputID
        if id == kAudioObjectUnknown { id = ProcessTapIO.defaultOutputDeviceID() }
        return id
    }

    private func configureGraph(
        appTaps: [ProcessTapIO.AppTapHandle],
        outputDeviceID: AudioObjectID
    ) throws {
        selectedOutputDeviceID = outputDeviceID
        outputDeviceName = Self.deviceName(outputDeviceID) ?? "Default Output"

        let rate = ProcessTapIO.deviceSampleRate(outputDeviceID)
        sampleRate = rate
        equalizer.setSampleRate(rate)
        limiter.setSampleRate(rate)
        Self.trySetSampleRate(outputDeviceID, rate: rate)

        let bufferFrames: UInt32 = 512
        Self.trySetBufferFrames(outputDeviceID, frames: bufferFrames)

        let asbd = Self.stereoFloatNonInterleavedASBD(sampleRate: rate)
        let ringCap = Int(rate * 0.35)

        var streams: [StreamContext] = []
        for handle in appTaps {
            Self.trySetSampleRate(handle.aggregateDeviceID, rate: rate)
            Self.trySetBufferFrames(handle.aggregateDeviceID, frames: bufferFrames)

            let stream = StreamContext(pid: handle.pid, ringCapacity: ringCap)
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
        let mix = MixContext(
            equalizer: equalizer,
            limiter: limiter,
            levels: levels,
            spectrum: spectrum,
            spectrumInput: spectrumInput,
            mixer: mixer,
            streams: streams
        )
        mixContext = mix

        // Output unit
        let outUnit = try makeHALUnit()
        try setEnableIO(outUnit, input: false, output: true)
        try setCurrentDevice(outUnit, outputDeviceID)
        try setMaxFrames(outUnit, frames: UInt32(mix.maxFrames))
        try setStreamFormat(outUnit, scope: kAudioUnitScope_Input, element: 0, asbd: asbd)

        let mixRef = Unmanaged.passUnretained(mix).toOpaque()
        var outputCB = AURenderCallbackStruct(inputProc: mixOutputCallback, inputProcRefCon: mixRef)
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

        // Start captures immediately; prime output after a brief, non-blocking delay
        // so the main thread never stalls in Thread.sleep.
        for stream in streams {
            if let unit = stream.unit {
                try OSStatusCheck(AudioOutputUnitStart(unit), "Start input pid=\(stream.pid)")
            }
        }

        mix.capturePrimed = false
        try OSStatusCheck(AudioOutputUnitStart(outUnit), "Start output unit")
        outputUnit = outUnit

        let weakMix = mix
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
            weakMix.capturePrimed = true
        }
    }

    private func teardownUnits() {
        if let out = outputUnit {
            AudioOutputUnitStop(out)
            AudioUnitUninitialize(out)
            AudioComponentInstanceDispose(out)
        }
        outputUnit = nil

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

    private func startIOStatusPoll() {
        stopIOStatusPoll()
        ioStatusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let mix = self.mixContext else { return }
                let totalCB = mix.streams.reduce(UInt64(0)) { $0 + $1.callbacks }
                let failing = mix.streams.filter { $0.lastStatus != noErr }.count
                let live = mix.streams.filter { $0.framesWithSignal > 0 }.count
                let next: String?
                if mix.streams.isEmpty {
                    next = "No app taps"
                } else if totalCB == 0 {
                    next = "No capture callbacks"
                } else if failing == mix.streams.count, mix.streams.count > 0 {
                    next = "All captures failing (\(mix.streams.first?.lastStatus ?? 0))"
                } else if live == 0, mix.outputCallbacks > 80 {
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
                    self.startSystemRouting(routedPIDs: self.routedPIDsProvider?() ?? [])
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

    stream.ring.write(left: stream.left, right: stream.right, count: frames)
    return noErr
}

// MARK: - Mix + EQ output

private func mixOutputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData else { return noErr }
    let ctx = Unmanaged<AudioEngineController.MixContext>.fromOpaque(inRefCon).takeUnretainedValue()
    ctx.outputCallbacks &+= 1

    let frames = Int(inNumberFrames)
    guard frames > 0, frames <= ctx.maxFrames else {
        zeroABL(ioData)
        return noErr
    }

    if !ctx.capturePrimed {
        zeroABL(ioData)
        return noErr
    }

    // Clear mix bus
    memset(ctx.mixLeft, 0, frames * 4)
    memset(ctx.mixRight, 0, frames * 4)

    // Sum each app with its volume / balance / mute / solo
    for stream in ctx.streams {
        let got = stream.ring.read(left: ctx.tmpLeft, right: ctx.tmpRight, count: frames)
        if got == 0 { continue }
        ctx.mixer.mix(
            pid: stream.pid,
            sourceLeft: ctx.tmpLeft,
            sourceRight: ctx.tmpRight,
            destLeft: ctx.mixLeft,
            destRight: ctx.mixRight,
            frameCount: frames
        )
    }

    // Soft-clip if multiple apps sum hot (vectorized hard clip).
    var negOne: Float = -1
    var posOne: Float = 1
    vDSP_vclip(ctx.mixLeft, 1, &negOne, &posOne, ctx.mixLeft, 1, vDSP_Length(frames))
    vDSP_vclip(ctx.mixRight, 1, &negOne, &posOne, ctx.mixRight, 1, vDSP_Length(frames))

    // Input spectrum (pre-EQ) — every 4th block is enough for UI meters.
    ctx.spectrumStride &+= 1
    if (ctx.spectrumStride & 3) == 0 {
        // Mid mix mono for analyzer
        var half: Float = 0.5
        vDSP_vasm(ctx.mixLeft, 1, ctx.mixRight, 1, &half, ctx.tmpLeft, 1, vDSP_Length(frames))
        // vasm is a+b then *C? Actually vDSP_vasm: C*(A+B). Good for (L+R)*0.5
        ctx.spectrumInput.push(samples: ctx.tmpLeft, count: frames)
    }

    ctx.equalizer.processChannels(left: ctx.mixLeft, right: ctx.mixRight, frameCount: frames)
    ctx.limiter.process(left: ctx.mixLeft, right: ctx.mixRight, frameCount: frames)
    ctx.levels.process(left: ctx.mixLeft, right: ctx.mixRight, frameCount: frames)
    if (ctx.spectrumStride & 3) == 0 {
        ctx.spectrum.push(samples: ctx.mixLeft, count: frames)
    }

    let byteSize = UInt32(frames * 4)
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    if abl.count >= 2 {
        if let p = abl[0].mData?.assumingMemoryBound(to: Float.self) {
            memcpy(p, ctx.mixLeft, frames * 4)
            abl[0].mDataByteSize = byteSize
        }
        if let p = abl[1].mData?.assumingMemoryBound(to: Float.self) {
            memcpy(p, ctx.mixRight, frames * 4)
            abl[1].mDataByteSize = byteSize
        }
    } else if abl.count == 1, let p = abl[0].mData?.assumingMemoryBound(to: Float.self) {
        let ch = max(Int(abl[0].mNumberChannels), 1)
        if ch == 1 {
            for i in 0..<frames { p[i] = 0.5 * (ctx.mixLeft[i] + ctx.mixRight[i]) }
        } else {
            for i in 0..<frames {
                p[i * ch] = ctx.mixLeft[i]
                p[i * ch + 1] = ctx.mixRight[i]
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
}
