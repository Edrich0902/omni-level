import AppKit
import CoreAudio
import Foundation
import os

/// App list + wires per-app volume/balance/EQ/routing into the multi-tap mix engine.
@MainActor
public final class AppAudioTapManager: ObservableObject {
    @Published public private(set) var runningAppAudioNodes: [AppAudioNode] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var engineStatusMessage: String = ""
    @Published public private(set) var isSystemRoutingActive = false
    @Published public private(set) var isConnecting = false
    /// Master bypass — all taps destroyed; dry system audio.
    @Published public private(set) var isOmniLevelBypassed = false
    @Published public private(set) var eqOverrideAppCount: Int = 0
    /// Live per-app loudness (dBFS). Not published, so ~30 Hz meter updates only redraw
    /// the meter views that read it, not every view observing the manager.
    public let liveLevels = LiveLevelFeed()
    public var liveLevelsdB: [pid_t: Float] { liveLevels.levels }

    public let engine: AudioEngineController
    public let perAppEQ = PerAppEQStore()
    public let appRoutes = AppRouteStore()
    public let mixerState = MixerStateStore()
    public let appList = AppListStore()

    private let identity = ProcessIdentity()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var deviceObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var meterTimer: Timer?
    private var persistTask: Task<Void, Never>?
    /// Apps that bypass OmniLevel (play straight to the system).
    private var bypassPIDs: Set<pid_t> = []
    private var rebuildTask: Task<Void, Never>?
    private var launchRetryTask: Task<Void, Never>?
    private var isRebuildingRoute = false
    private var lastRebuildAttempt = Date.distantPast
    /// Last known audio PID sets per card — detect late helper registration.
    private var lastClusterAudioPIDs: [pid_t: Set<pid_t>] = [:]
    private let log = Logger(subsystem: "com.omnilevel.app", category: "tapManager")

    public init(engine: AudioEngineController = AudioEngineController()) {
        self.engine = engine
        engine.routedClustersProvider = { [weak self] in
            self?.computeRoutedClusters() ?? []
        }
        engine.streamRouteProvider = { [weak self] pid in
            guard let self else { return nil }
            guard let node = self.runningAppAudioNodes.first(where: { $0.id == pid }) else {
                return nil
            }
            return node.outputDeviceUID
        }
        isOmniLevelBypassed = mixerState.isOmniLevelBypassed
        observeWorkspace()
        observeDeviceChanges()
        refreshActiveAudioProcesses()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshActiveAudioProcesses()
            }
        }
    }

    /// Level metering only runs while UI is on screen. Visible meters pump faster on their
    /// own; this low-rate timer keeps quiet-app tracking / Monitor stats fresh meanwhile.
    public func setLiveMetersActive(_ active: Bool) {
        meterTimer?.invalidate()
        meterTimer = nil
        guard active else { return }
        updatePeakLevelsFromEngine()
        let meter = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePeakLevelsFromEngine() }
        }
        RunLoop.main.add(meter, forMode: .common)
        meterTimer = meter
    }

    public func clearError() {
        lastError = nil
    }

    public func shutdown() {
        rebuildTask?.cancel()
        launchRetryTask?.cancel()
        persistTask?.cancel()
        flushMixerState()
        for o in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        workspaceObservers.removeAll()
        if let deviceObserver {
            NotificationCenter.default.removeObserver(deviceObserver)
            self.deviceObserver = nil
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
        meterTimer?.invalidate()
        meterTimer = nil
        engine.stopSystemRouting()
        isSystemRoutingActive = false
    }

    public func bootstrap() {
        if isOmniLevelBypassed {
            isConnecting = false
            engineStatusMessage = "Bypassed — system audio"
            updateStatus()
            return
        }
        isConnecting = true
        engineStatusMessage = "Connecting audio…"
        Task { @MainActor in
            await Task.yield()
            self.rebuildSystemRoute(reason: "bootstrap")
            self.scheduleLaunchRecovery()
        }
    }

    public func startEngine() {
        setOmniLevelBypassed(false)
    }

    public func stopEngine() {
        launchRetryTask?.cancel()
        engine.stopSystemRouting()
        isSystemRoutingActive = false
        markAllTapped(false)
        updateStatus()
    }

    // MARK: - Master bypass

    public func setOmniLevelBypassed(_ bypassed: Bool) {
        guard isOmniLevelBypassed != bypassed else {
            if !bypassed { rebuildSystemRoute(reason: "unbypass") }
            return
        }
        isOmniLevelBypassed = bypassed
        mixerState.setMasterBypass(bypassed)
        if bypassed {
            launchRetryTask?.cancel()
            rebuildTask?.cancel()
            engine.stopSystemRouting()
            isSystemRoutingActive = false
            isConnecting = false
            markAllTapped(false)
            lastError = nil
            engineStatusMessage = "Bypassed — system audio"
            log.info("OmniLevel master bypass ON")
        } else {
            log.info("OmniLevel master bypass OFF")
            rebuildSystemRoute(reason: "unbypass")
            scheduleLaunchRecovery()
        }
        updateStatus()
    }

    public func toggleOmniLevelBypass() {
        setOmniLevelBypassed(!isOmniLevelBypassed)
    }

    public func refreshActiveAudioProcesses() {
        let apps = identity.candidateApplications()
        var previous: [pid_t: AppAudioNode] = [:]
        for node in runningAppAudioNodes { previous[node.id] = node }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let liveHandles = engine.processTaps.currentAppTaps()
        let liveTaps = Set(liveHandles.map(\.pid))
        let liveTapAudio = Dictionary(uniqueKeysWithValues: liveHandles.map { ($0.pid, Set($0.audioPIDs)) })
        var nodes: [AppAudioNode] = []
        var needsClusterRebuild = false

        for app in apps {
            let pid = app.processIdentifier
            if pid == ownPID { continue }

            let bundleID = app.bundleIdentifier
            let storedMixer = mixerState.entry(forBundleID: bundleID)
            if previous[pid] == nil, let storedMixer, storedMixer.bypassed {
                bypassPIDs.insert(pid)
            }

            let wantRoute = !isOmniLevelBypassed && !bypassPIDs.contains(pid)
            let related = identity.relatedPIDs(for: app)
            // Probe Core Audio only for apps we route — avoids main-thread storms.
            let audioPIDs: [pid_t]
            if wantRoute || liveTaps.contains(pid) {
                audioPIDs = identity.tapAudioPIDs(for: app, related: related)
            } else {
                audioPIDs = []
            }
            // Empty means "no Core Audio process yet" — do not pretend main PID is tappable.
            let audioSet = Set(audioPIDs)
            lastClusterAudioPIDs[pid] = audioSet

            if wantRoute, liveTaps.contains(pid), let liveAudio = liveTapAudio[pid] {
                if audioSet != liveAudio {
                    needsClusterRebuild = true
                }
            } else if wantRoute, isSystemRoutingActive, !liveTaps.contains(pid), !audioPIDs.isEmpty {
                needsClusterRebuild = true
            }

            let storedUID = appRoutes.outputDeviceUID(forBundleID: bundleID)
            let resolved = engine.resolveOutputDevice(uid: storedUID, refresh: false)
            let effectiveUID: String? = {
                guard let storedUID else { return nil }
                return resolved.fallback ? nil : storedUID
            }()
            let hasEQ = perAppEQ.hasOverride(forBundleID: bundleID)

            let desiredThrough = !isOmniLevelBypassed && isSystemRoutingActive && computeRoutedSet().contains(pid)
            let isThrough = desiredThrough && liveTaps.contains(pid)

            if let existing = previous[pid] {
                nodes.append(AppAudioNode(
                    id: pid,
                    appName: app.localizedName ?? existing.appName,
                    bundleIdentifier: bundleID ?? existing.bundleIdentifier,
                    appIcon: app.icon ?? existing.appIcon,
                    volume: existing.volume,
                    pan: existing.pan,
                    isMuted: existing.isMuted,
                    isSolo: existing.isSolo,
                    isTapped: isThrough,
                    peakLeveldB: existing.peakLeveldB,
                    hasEQOverride: hasEQ,
                    outputDeviceUID: effectiveUID,
                    outputFallback: resolved.fallback && storedUID != nil
                ))
            } else if let icon = app.icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) {
                let hydrated = storedMixer
                nodes.append(AppAudioNode(
                    id: pid,
                    appName: app.localizedName ?? "Unknown",
                    bundleIdentifier: bundleID,
                    appIcon: icon,
                    volume: hydrated?.volume ?? 1,
                    pan: hydrated?.pan ?? 0,
                    isMuted: hydrated?.isMuted ?? false,
                    isSolo: hydrated?.isSolo ?? false,
                    isTapped: isThrough,
                    peakLeveldB: -60,
                    hasEQOverride: hasEQ,
                    outputDeviceUID: effectiveUID,
                    outputFallback: resolved.fallback && storedUID != nil
                ))
            }
        }

        let alive = Set(nodes.map(\.id))
        lastClusterAudioPIDs = lastClusterAudioPIDs.filter { alive.contains($0.key) }
        bypassPIDs = bypassPIDs.intersection(alive)

        let sorted = nodes.sorted {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
        if !appNodesEqual(runningAppAudioNodes, sorted) {
            runningAppAudioNodes = sorted
        }
        syncAllMixerParams()
        eqOverrideAppCount = perAppEQ.overrideCount
        updateStatus()

        if needsClusterRebuild, isSystemRoutingActive, !isOmniLevelBypassed,
           Date().timeIntervalSince(lastRebuildAttempt) > 0.75 {
            scheduleRouteRebuild()
        }
    }

    private func appNodesEqual(_ a: [AppAudioNode], _ b: [AppAudioNode]) -> Bool {
        guard a.count == b.count else { return false }
        for i in a.indices {
            let x = a[i], y = b[i]
            if x.id != y.id
                || x.appName != y.appName
                || x.bundleIdentifier != y.bundleIdentifier
                || abs(x.volume - y.volume) > 0.001
                || abs(x.pan - y.pan) > 0.001
                || x.isMuted != y.isMuted
                || x.isSolo != y.isSolo
                || x.isTapped != y.isTapped
                || x.hasEQOverride != y.hasEQOverride
                || x.outputDeviceUID != y.outputDeviceUID
                || x.outputFallback != y.outputFallback {
                return false
            }
        }
        return true
    }

    public func setVolume(pid: pid_t, volume: Float) {
        updateNode(pid: pid) { $0.volume = max(0, min(2, volume)) }
        syncMixer(pid: pid)
        schedulePersistMixerState()
    }

    public func setPan(pid: pid_t, pan: Float) {
        updateNode(pid: pid) { $0.pan = max(-1, min(1, pan)) }
        syncMixer(pid: pid)
        schedulePersistMixerState()
    }

    public func setMuted(pid: pid_t, muted: Bool) {
        updateNode(pid: pid) { $0.isMuted = muted }
        if muted {
            bypassPIDs.remove(pid)
            if isSystemRoutingActive, !isOmniLevelBypassed, !computeRoutedSet().contains(pid) {
                scheduleRouteRebuild()
            } else {
                markAllTappedThroughRoute()
            }
        }
        syncMixer(pid: pid)
        schedulePersistMixerState()
    }

    public func setSolo(pid: pid_t, solo: Bool) {
        updateNode(pid: pid) { $0.isSolo = solo }
        syncAllMixerParams()
        scheduleRouteRebuild()
        schedulePersistMixerState()
    }

    public func toggleMute(pid: pid_t) {
        guard let n = runningAppAudioNodes.first(where: { $0.id == pid }) else { return }
        setMuted(pid: pid, muted: !n.isMuted)
    }

    public func toggleSolo(pid: pid_t) {
        guard let n = runningAppAudioNodes.first(where: { $0.id == pid }) else { return }
        setSolo(pid: pid, solo: !n.isSolo)
    }

    public func toggleTap(for pid: pid_t) {
        let currentlyDesired = !bypassPIDs.contains(pid)
        let currentlyLive = runningAppAudioNodes.first(where: { $0.id == pid })?.isTapped ?? false
        if currentlyDesired && currentlyLive {
            setRoute(pid: pid, throughOmniLevel: false)
        } else {
            setRoute(pid: pid, throughOmniLevel: true)
        }
    }

    public func setRoute(pid: pid_t, throughOmniLevel: Bool) {
        if throughOmniLevel {
            bypassPIDs.remove(pid)
            updateNode(pid: pid) {
                $0.isTapped = false
                if $0.isMuted { $0.isMuted = false }
            }
        } else {
            bypassPIDs.insert(pid)
            updateNode(pid: pid) {
                $0.isTapped = false
                $0.isMuted = false
            }
        }
        syncMixer(pid: pid)
        schedulePersistMixerState()
        scheduleRouteRebuild()
    }

    // MARK: - Per-app EQ

    public func setEQOverride(
        pid: pid_t,
        gains: [Float],
        qFactors: [Float]? = nil,
        name: String? = nil
    ) {
        guard let node = runningAppAudioNodes.first(where: { $0.id == pid }),
              let bundleID = node.bundleIdentifier, !bundleID.isEmpty else { return }
        perAppEQ.setOverride(bundleID: bundleID, gainsdB: gains, qFactors: qFactors, name: name)
        engine.setStreamEQOverride(pid: pid, gains: gains, qFactors: qFactors)
        updateNode(pid: pid) { $0.hasEQOverride = true }
        eqOverrideAppCount = perAppEQ.overrideCount
        updateStatus()
    }

    public func clearEQOverride(pid: pid_t) {
        guard let node = runningAppAudioNodes.first(where: { $0.id == pid }),
              let bundleID = node.bundleIdentifier else { return }
        perAppEQ.removeOverride(bundleID: bundleID)
        engine.clearStreamEQOverride(pid: pid)
        updateNode(pid: pid) { $0.hasEQOverride = false }
        eqOverrideAppCount = perAppEQ.overrideCount
        updateStatus()
    }

    public func eqOverrideEntry(for pid: pid_t) -> PerAppEQStore.Entry? {
        guard let node = runningAppAudioNodes.first(where: { $0.id == pid }) else { return nil }
        return perAppEQ.entry(forBundleID: node.bundleIdentifier)
    }

    // MARK: - Per-app output routing

    public func setOutputDeviceUID(_ uid: String?, for pid: pid_t) {
        guard let node = runningAppAudioNodes.first(where: { $0.id == pid }),
              let bundleID = node.bundleIdentifier, !bundleID.isEmpty else { return }
        appRoutes.setOutputDeviceUID(uid, forBundleID: bundleID)
        let resolved = engine.resolveOutputDevice(uid: uid)
        updateNode(pid: pid) {
            $0.outputDeviceUID = resolved.fallback ? nil : uid
            $0.outputFallback = resolved.fallback && uid != nil
        }
        scheduleRouteRebuild()
    }

    // MARK: - Mixer sync

    private func syncMixer(pid: pid_t) {
        guard let node = runningAppAudioNodes.first(where: { $0.id == pid }) else { return }
        engine.mixer.setStream(pid, params: .init(
            volume: node.volume,
            pan: node.pan,
            isMuted: node.isMuted,
            isSolo: node.isSolo
        ))
    }

    private func syncAllMixerParams() {
        for node in runningAppAudioNodes {
            engine.mixer.setStream(node.id, params: .init(
                volume: node.volume,
                pan: node.pan,
                isMuted: node.isMuted,
                isSolo: node.isSolo
            ))
        }
    }

    private func syncEQOverridesWithEngine() {
        for node in runningAppAudioNodes {
            if let entry = perAppEQ.entry(forBundleID: node.bundleIdentifier) {
                // Avoid re-applying (and resetting biquad state) every refresh tick.
                if !engine.hasEQOverride(pid: node.id) {
                    engine.setStreamEQOverride(pid: node.id, gains: entry.gainsdB, qFactors: entry.qFactors)
                }
            } else if engine.hasEQOverride(pid: node.id) {
                engine.clearStreamEQOverride(pid: node.id)
            }
        }
    }

    // MARK: - Mixer persistence + meters

    private func schedulePersistMixerState() {
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self.flushMixerState()
        }
    }

    private func flushMixerState() {
        var apps: [String: MixerStateStore.AppEntry] = mixerState.apps
        for node in runningAppAudioNodes {
            guard let bundleID = node.bundleIdentifier, !bundleID.isEmpty else { continue }
            apps[bundleID] = MixerStateStore.AppEntry(
                volume: node.volume,
                pan: node.pan,
                isMuted: node.isMuted,
                isSolo: node.isSolo,
                bypassed: bypassPIDs.contains(node.id)
            )
        }
        mixerState.replaceSnapshot(apps: apps, masterBypass: isOmniLevelBypassed)
    }

    private func updatePeakLevelsFromEngine() {
        let peaks = engine.snapshotPeakLevels()
        let nodes = runningAppAudioNodes
        guard !nodes.isEmpty else {
            liveLevels.update([:])
            return
        }

        let current = liveLevels.levels
        var next: [pid_t: Float] = [:]
        next.reserveCapacity(nodes.count)
        for node in nodes {
            let prev = current[node.id] ?? -60
            if node.isTapped, let live = peaks[node.id] {
                next[node.id] = live
            } else {
                next[node.id] = max(-60, prev - 4)
            }
        }
        liveLevels.update(next)
    }

    /// Snapshot + publish live levels. Call from a TimelineView while the Apps pane is visible
    /// (NSPopover often won't redraw from Timer-driven @Published alone).
    public func pumpLiveLevels() {
        updatePeakLevelsFromEngine()
    }

    public func liveLeveldB(for pid: pid_t) -> Float {
        liveLevels.levels[pid] ?? -60
    }

    // MARK: - Route rebuild

    private func scheduleRouteRebuild() {
        guard !isOmniLevelBypassed else { return }
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            rebuildSystemRoute(reason: "user")
        }
    }

    private func scheduleLaunchRecovery() {
        launchRetryTask?.cancel()
        guard !isOmniLevelBypassed else { return }
        launchRetryTask = Task { @MainActor in
            let deadline = Date().addingTimeInterval(3.0)
            var attempt = 0
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled, !self.isOmniLevelBypassed else { return }
                attempt += 1
                self.refreshActiveAudioProcesses()
                let desired = self.computeRoutedSet()
                let live = Set(self.engine.processTaps.currentAppTaps().map(\.pid))
                let missing = desired.subtracting(live)
                if missing.isEmpty, self.engine.activeStreamCount > 0 {
                    self.log.info("launch recovery settled after \(attempt) tries")
                    return
                }
                if !desired.isEmpty {
                    self.log.info("launch recovery retry #\(attempt) missing=\(missing.count)")
                    self.rebuildSystemRoute(reason: "launch-retry")
                }
            }
        }
    }

    private func rebuildSystemRoute(reason: String) {
        guard !isOmniLevelBypassed else {
            isConnecting = false
            updateStatus()
            return
        }
        guard !isRebuildingRoute else { return }
        if reason == "bootstrap", Date().timeIntervalSince(lastRebuildAttempt) < 0.4 {
            return
        }
        lastRebuildAttempt = Date()
        isRebuildingRoute = true
        let wasLive = isSystemRoutingActive && engine.isRouting
        if !wasLive {
            isConnecting = true
            engineStatusMessage = "Connecting audio…"
        }

        Task { @MainActor in
            await Task.yield()
            if self.isOmniLevelBypassed {
                self.isRebuildingRoute = false
                self.isConnecting = false
                self.updateStatus()
                return
            }
            let clusters = self.computeRoutedClusters()
            self.syncAllMixerParams()
            self.syncEQOverridesWithEngine()
            self.engine.startSystemRouting(routedClusters: clusters)
            self.isRebuildingRoute = false
            self.isConnecting = false

            switch self.engine.state {
            case .running where self.engine.isRouting:
                self.isSystemRoutingActive = true
                self.lastError = nil
                self.markAllTappedThroughRoute()
            case .error(let message):
                // Auto-bypass rather than silent mute.
                self.log.error("engine error → auto-bypass: \(message, privacy: .public)")
                self.lastError = message
                self.isOmniLevelBypassed = true
                self.isSystemRoutingActive = false
                self.engine.stopSystemRouting()
                self.markAllTapped(false)
            default:
                self.isSystemRoutingActive = false
                self.markAllTapped(false)
            }
            self.refreshActiveAudioProcesses()
            self.updateStatus()
        }
    }

    /// Prefer browser helpers for YouTube/etc.; Spotify-class apps keep main-only taps.
    private func computeRoutedClusters() -> [ProcessTapIO.TapCluster] {
        let routed = computeRoutedSet()
        let apps = identity.candidateApplications()
        var clusters: [ProcessTapIO.TapCluster] = []
        for app in apps {
            let pid = app.processIdentifier
            guard routed.contains(pid) else { continue }
            let related = identity.relatedPIDs(for: app)
            let audioPIDs = identity.tapAudioPIDs(for: app, related: related)
            // Skip cards with no CA-capable PIDs — createAppTap would return nil and
            // perpetual rebuild loops used to hammer Spotify/Arc every few seconds.
            guard !audioPIDs.isEmpty else { continue }
            if identity.isBrowserFamily(bundleID: app.bundleIdentifier, appName: app.localizedName) {
                log.info(
                    "browser cluster \(app.localizedName ?? "?", privacy: .public) main=\(pid) tapPIDs=\(audioPIDs.map(String.init).joined(separator: ","), privacy: .public) related=\(related.count)"
                )
            }
            clusters.append(
                ProcessTapIO.TapCluster(
                    keyPID: pid,
                    audioPIDs: audioPIDs
                )
            )
        }
        return clusters
    }

    private func computeRoutedSet() -> Set<pid_t> {
        if isOmniLevelBypassed { return [] }
        let soloed = runningAppAudioNodes.filter(\.isSolo).map(\.id)
        if !soloed.isEmpty {
            return Set(soloed)
        }
        return Set(runningAppAudioNodes.map(\.id).filter { !bypassPIDs.contains($0) })
    }

    private func markAllTapped(_ tapped: Bool) {
        let live = tapped ? Set(engine.processTaps.currentAppTaps().map(\.pid)) : []
        let routed = tapped ? computeRoutedSet() : []
        var nodes = runningAppAudioNodes
        for i in nodes.indices {
            let id = nodes[i].id
            nodes[i].isTapped = routed.contains(id) && live.contains(id)
        }
        runningAppAudioNodes = nodes
    }

    private func markAllTappedThroughRoute() {
        let live = Set(engine.processTaps.currentAppTaps().map(\.pid))
        let routed = computeRoutedSet()
        var nodes = runningAppAudioNodes
        for i in nodes.indices {
            let id = nodes[i].id
            nodes[i].isTapped = routed.contains(id) && live.contains(id)
        }
        runningAppAudioNodes = nodes
    }

    private func updateNode(pid: pid_t, mutate: (inout AppAudioNode) -> Void) {
        guard let idx = runningAppAudioNodes.firstIndex(where: { $0.id == pid }) else { return }
        // Reassign the array so @Published fires — in-place element mutation does not.
        var nodes = runningAppAudioNodes
        mutate(&nodes[idx])
        runningAppAudioNodes = nodes
    }

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        let launch = nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let before = self.computeRoutedSet()
                self.refreshActiveAudioProcesses()
                let after = self.computeRoutedSet()
                if before != after {
                    self.scheduleRouteRebuild()
                }
            }
        }
        let terminate = nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let before = self.computeRoutedSet()
                self.refreshActiveAudioProcesses()
                let after = self.computeRoutedSet()
                if before != after {
                    self.scheduleRouteRebuild()
                }
            }
        }
        workspaceObservers = [launch, terminate]
    }

    private func observeDeviceChanges() {
        deviceObserver = NotificationCenter.default.addObserver(
            forName: .omniLevelOutputDevicesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshActiveAudioProcesses()
            }
        }
    }

    private func updateStatus() {
        if isOmniLevelBypassed {
            engineStatusMessage = lastError.map { "Bypassed after error · \($0)" } ?? "Bypassed — system audio"
            return
        }
        if isConnecting {
            engineStatusMessage = "Connecting audio…"
            return
        }
        switch engine.state {
        case .running where isSystemRoutingActive:
            let routed = runningAppAudioNodes.filter(\.isTapped).count
            let outputs = engine.activeOutputSummary.isEmpty
                ? engine.outputDeviceName
                : engine.activeOutputSummary
            var status = "Listening: \(routed) apps · Outputs: \(outputs)"
            if let io = engine.lastIOError {
                status += " · \(io)"
            }
            engineStatusMessage = status
        case .error(let message):
            engineStatusMessage = message
        case .stopped:
            engineStatusMessage = lastError ?? "Stopped"
        default:
            engineStatusMessage = lastError ?? "Ready"
        }
    }
}

/// Per-app live loudness, read by meter views on their own display ticks.
@MainActor
public final class LiveLevelFeed {
    public private(set) var levels: [pid_t: Float] = [:]

    func update(_ next: [pid_t: Float]) {
        levels = next
    }
}
