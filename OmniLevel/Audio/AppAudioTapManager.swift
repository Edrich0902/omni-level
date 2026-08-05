import AppKit
import CoreAudio
import Foundation
import os

/// App list + wires per-app volume/balance into the multi-tap mix engine.
@MainActor
public final class AppAudioTapManager: ObservableObject {
    @Published public private(set) var runningAppAudioNodes: [AppAudioNode] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var engineStatusMessage: String = ""
    @Published public private(set) var isSystemRoutingActive = false
    @Published public private(set) var isConnecting = false

    public let engine: AudioEngineController
    private let identity = ProcessIdentity()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?
    /// Apps that bypass OmniLevel (play straight to the system).
    private var bypassPIDs: Set<pid_t> = []
    private var rebuildTask: Task<Void, Never>?
    private var isRebuildingRoute = false
    private var lastRebuildAttempt = Date.distantPast

    public init(engine: AudioEngineController = AudioEngineController()) {
        self.engine = engine
        engine.routedPIDsProvider = { [weak self] in
            self?.computeRoutedPIDs() ?? []
        }
        observeWorkspace()
        refreshActiveAudioProcesses()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshActiveAudioProcesses()
            }
        }
    }

    public func clearError() {
        lastError = nil
    }

    public func shutdown() {
        rebuildTask?.cancel()
        for o in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        workspaceObservers.removeAll()
        refreshTimer?.invalidate()
        refreshTimer = nil
        engine.stopSystemRouting()
        isSystemRoutingActive = false
    }

    public func bootstrap() {
        isConnecting = true
        engineStatusMessage = "Connecting audio…"
        Task { @MainActor in
            await Task.yield()
            self.rebuildSystemRoute(reason: "bootstrap")
        }
    }

    public func startEngine() {
        rebuildSystemRoute(reason: "start")
    }

    public func stopEngine() {
        engine.stopSystemRouting()
        isSystemRoutingActive = false
        markAllTapped(false)
        updateStatus()
    }

    public func refreshActiveAudioProcesses() {
        let apps = identity.candidateApplications()
        var previous: [pid_t: AppAudioNode] = [:]
        for node in runningAppAudioNodes { previous[node.id] = node }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var nodes: [AppAudioNode] = []

        for app in apps {
            let pid = app.processIdentifier
            if pid == ownPID { continue }
            let isThrough = isSystemRoutingActive && computeRoutedSet().contains(pid)
            if let existing = previous[pid] {
                nodes.append(AppAudioNode(
                    id: pid,
                    appName: app.localizedName ?? existing.appName,
                    bundleIdentifier: app.bundleIdentifier,
                    appIcon: app.icon ?? existing.appIcon,
                    volume: existing.volume,
                    pan: existing.pan,
                    isMuted: existing.isMuted,
                    isSolo: existing.isSolo,
                    isTapped: isThrough,
                    peakLeveldB: existing.peakLeveldB
                ))
            } else if let icon = app.icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) {
                nodes.append(AppAudioNode(
                    id: pid,
                    appName: app.localizedName ?? "Unknown",
                    bundleIdentifier: app.bundleIdentifier,
                    appIcon: icon,
                    isTapped: isThrough
                ))
            }
        }

        bypassPIDs = bypassPIDs.intersection(Set(nodes.map(\.id)))
        let sorted = nodes.sorted {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
        // Avoid invalidating the app list (and full popover tree) when nothing changed.
        if !appNodesEqual(runningAppAudioNodes, sorted) {
            runningAppAudioNodes = sorted
        }
        // Keep mixer table current even for apps we are not routing yet.
        syncAllMixerParams()
        updateStatus()
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
                || x.isTapped != y.isTapped {
                return false
            }
        }
        return true
    }

    public func setVolume(pid: pid_t, volume: Float) {
        updateNode(pid: pid) { $0.volume = max(0, min(2, volume)) }
        syncMixer(pid: pid)
    }

    public func setPan(pid: pid_t, pan: Float) {
        updateNode(pid: pid) { $0.pan = max(-1, min(1, pan)) }
        syncMixer(pid: pid)
    }

    public func setMuted(pid: pid_t, muted: Bool) {
        updateNode(pid: pid) { $0.isMuted = muted }
        // Mute must keep the app routed through OmniLevel so mutedWhenTapped can silence the original
        // and our mixer can output silence. Unmute restores previous route preference.
        if muted {
            bypassPIDs.remove(pid)
            updateNode(pid: pid) { $0.isTapped = isSystemRoutingActive }
            // Ensure a tap exists if engine is live.
            if isSystemRoutingActive, !computeRoutedSet().contains(pid) {
                scheduleRouteRebuild()
            }
        }
        syncMixer(pid: pid)
    }

    public func setSolo(pid: pid_t, solo: Bool) {
        updateNode(pid: pid) { $0.isSolo = solo }
        syncAllMixerParams()
        // Solo changes who needs a tap vs system playback.
        scheduleRouteRebuild()
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
        let through = !(runningAppAudioNodes.first(where: { $0.id == pid })?.isTapped ?? true)
        setRoute(pid: pid, throughOmniLevel: through)
    }

    public func setRoute(pid: pid_t, throughOmniLevel: Bool) {
        if throughOmniLevel {
            bypassPIDs.remove(pid)
            updateNode(pid: pid) {
                $0.isTapped = isSystemRoutingActive
                // Turning routing back on clears mute so audio returns.
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
        scheduleRouteRebuild()
    }

    // MARK: - Mixer sync (instant; no graph rebuild)

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

    // MARK: - Route rebuild

    private func scheduleRouteRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            rebuildSystemRoute(reason: "user")
        }
    }

    private func rebuildSystemRoute(reason: String) {
        guard !isRebuildingRoute else { return }
        if reason != "bootstrap", Date().timeIntervalSince(lastRebuildAttempt) < 1.2 {
            return
        }
        lastRebuildAttempt = Date()
        isRebuildingRoute = true
        isConnecting = true
        engineStatusMessage = "Connecting audio…"

        Task { @MainActor in
            await Task.yield()
            let pids = self.computeRoutedPIDs()
            self.syncAllMixerParams()
            self.engine.startSystemRouting(routedPIDs: pids)
            self.isRebuildingRoute = false
            self.isConnecting = false

            switch self.engine.state {
            case .running where self.engine.isRouting:
                self.isSystemRoutingActive = true
                self.lastError = nil
                self.markAllTappedThroughRoute()
            case .error(let message):
                self.isSystemRoutingActive = false
                self.lastError = message
                self.markAllTapped(false)
            default:
                self.isSystemRoutingActive = false
                self.markAllTapped(false)
            }
            self.updateStatus()
        }
    }

    /// PIDs that should be process-tapped (through OmniLevel with volume/balance).
    private func computeRoutedPIDs() -> [pid_t] {
        Array(computeRoutedSet())
    }

    private func computeRoutedSet() -> Set<pid_t> {
        let soloed = runningAppAudioNodes.filter(\.isSolo).map(\.id)
        if !soloed.isEmpty {
            // Solo: only soloed apps go through OmniLevel; others play via the system.
            return Set(soloed)
        }
        // Default: every app not marked Off/bypass.
        return Set(runningAppAudioNodes.map(\.id).filter { !bypassPIDs.contains($0) })
    }

    private func markAllTapped(_ tapped: Bool) {
        let routed = tapped ? computeRoutedSet() : []
        for i in runningAppAudioNodes.indices {
            runningAppAudioNodes[i].isTapped = routed.contains(runningAppAudioNodes[i].id)
        }
    }

    private func markAllTappedThroughRoute() {
        let routed = computeRoutedSet()
        for i in runningAppAudioNodes.indices {
            runningAppAudioNodes[i].isTapped = routed.contains(runningAppAudioNodes[i].id)
        }
    }

    private func updateNode(pid: pid_t, mutate: (inout AppAudioNode) -> Void) {
        guard let idx = runningAppAudioNodes.firstIndex(where: { $0.id == pid }) else { return }
        mutate(&runningAppAudioNodes[idx])
    }

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        let launch = nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshActiveAudioProcesses()
                // New apps default to "On" — rebuild so they get a tap.
                self?.scheduleRouteRebuild()
            }
        }
        let terminate = nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshActiveAudioProcesses()
                self?.scheduleRouteRebuild()
            }
        }
        workspaceObservers = [launch, terminate]
    }

    private func updateStatus() {
        if isConnecting {
            engineStatusMessage = "Connecting audio…"
            return
        }
        switch engine.state {
        case .running where isSystemRoutingActive:
            let routed = runningAppAudioNodes.filter(\.isTapped).count
            var status = "Live · \(engine.outputDeviceName) · \(routed) apps"
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
