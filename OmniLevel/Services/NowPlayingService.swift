import AppKit
import Foundation
import os

/// Dual-source Now Playing: Spotify (AppleScript) + system MediaRemote (browser/etc).
@MainActor
final class NowPlayingService: ObservableObject {
    @Published private(set) var players: [NowPlayingItem] = []
    @Published private(set) var automationHint: String?

    private var timer: Timer?
    private var artworkCache: [String: NSImage] = [:]
    private var systemArtCache: [String: NSImage] = [:]
    private let log = Logger(subsystem: "com.omnilevel.app", category: "nowPlaying")
    private var refreshTask: Task<Void, Never>?
    private var isRefreshing = false
    private var consecutiveIdlePolls = 0

    init() {}

    func start() {
        stop()
        Task { await refresh() }
        // Adaptive: 1s when playing, slower when idle (reapplied each refresh).
        scheduleTimer(interval: 1.0)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func refresh() async {
        // Single-flight: skip if previous cycle still running (AppleScript / MediaRemote).
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var next: [NowPlayingItem] = []

        // 1) Spotify — off main actor (AppleScript is blocking).
        if let spotify = await fetchSpotify() {
            next.append(spotify)
            automationHint = nil
        } else if SpotifyController.isRunning {
            automationHint = "Allow Automation for Spotify in System Settings → Privacy & Security"
        }

        // 2) System Media Remote
        if let system = await fetchSystemNowPlaying(
            excludingSpotifyIfPresent: next.contains(where: { $0.source == .spotify })
        ) {
            next.append(system)
        }

        next.sort { a, b in
            if a.source == b.source { return a.appName < b.appName }
            return a.source == .spotify
        }

        // Publish only when UI-visible state actually changes.
        // Live position is interpolated in seek bars between polls (no 1 Hz SwiftUI churn).
        if !playersVisuallyEqual(players, next) {
            players = next
        }

        // Idle: poll less; active: keep ~1s so transport stays snappy.
        let idle = next.isEmpty
        if idle {
            consecutiveIdlePolls += 1
            if consecutiveIdlePolls == 1 || consecutiveIdlePolls % 4 == 0 {
                scheduleTimer(interval: 2.5)
            }
        } else {
            if consecutiveIdlePolls > 0 {
                scheduleTimer(interval: 1.0)
            }
            consecutiveIdlePolls = 0
        }
    }

    /// True when UI would look the same (ignore high-frequency progress fields).
    private func playersVisuallyEqual(_ a: [NowPlayingItem], _ b: [NowPlayingItem]) -> Bool {
        guard a.count == b.count else { return false }
        for i in a.indices {
            let x = a[i], y = b[i]
            if x.id != y.id
                || x.title != y.title
                || x.artist != y.artist
                || x.album != y.album
                || x.isPlaying != y.isPlaying
                || x.appName != y.appName
                || x.source != y.source
                || (x.artwork == nil) != (y.artwork == nil)
                || abs((x.duration ?? 0) - (y.duration ?? 0)) > 0.5 {
                return false
            }
        }
        return true
    }

    func togglePlayPause(_ item: NowPlayingItem) {
        switch item.source {
        case .spotify:
            SpotifyController.togglePlayPause()
        case .system:
            _ = MediaRemoteBridge.send(.togglePlayPause)
        }
        scheduleQuickRefresh()
    }

    func next(_ item: NowPlayingItem) {
        switch item.source {
        case .spotify:
            SpotifyController.nextTrack()
        case .system:
            _ = MediaRemoteBridge.send(.nextTrack)
        }
        scheduleQuickRefresh()
    }

    func previous(_ item: NowPlayingItem) {
        switch item.source {
        case .spotify:
            SpotifyController.previousTrack()
        case .system:
            _ = MediaRemoteBridge.send(.previousTrack)
        }
        scheduleQuickRefresh()
    }

    func seek(_ item: NowPlayingItem, to seconds: TimeInterval) {
        guard let duration = item.duration, duration > 0 else { return }
        let clamped = min(max(seconds, 0), duration)
        switch item.source {
        case .spotify:
            SpotifyController.setPosition(clamped)
            if let idx = players.firstIndex(where: { $0.id == item.id }) {
                players[idx].position = clamped
                players[idx].progressSampledAt = .now
            }
        case .system:
            if MediaRemoteBridge.seek(to: clamped) {
                if let idx = players.firstIndex(where: { $0.id == item.id }) {
                    players[idx].position = clamped
                    players[idx].progressSampledAt = .now
                }
            }
        }
        scheduleQuickRefresh()
    }

    private func scheduleQuickRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            // Bypass single-flight only after transport by resetting isRefreshing wait.
            await refresh()
        }
    }

    // MARK: - Spotify

    private func fetchSpotify() async -> NowPlayingItem? {
        guard SpotifyController.isRunning else { return nil }

        let state: SpotifyController.State? = await Task.detached(priority: .utility) {
            SpotifyController.fetchState()
        }.value
        guard let state else { return nil }

        var art = artworkCache[state.artworkURL ?? ""]
        if art == nil, let urlStr = state.artworkURL, let url = URL(string: urlStr) {
            art = await downloadImage(url)
            if let art { artworkCache[urlStr] = art }
        }

        let hasDuration = state.duration > 0.5
        return NowPlayingItem(
            id: "spotify",
            source: .spotify,
            appName: "Spotify",
            bundleID: SpotifyController.bundleID,
            title: state.title,
            artist: state.artist,
            album: state.album,
            isPlaying: state.isPlaying,
            artwork: art,
            appIcon: SpotifyController.appIcon(),
            position: hasDuration ? state.position : nil,
            duration: hasDuration ? state.duration : nil,
            playbackRate: state.isPlaying ? 1 : 0,
            progressSampledAt: .now,
            canSeek: hasDuration
        )
    }

    // MARK: - System MediaRemote

    private struct MediaRemoteSnapshot: Sendable {
        let title: String
        let artist: String
        let album: String
        let isPlaying: Bool
        let pid: pid_t?
        let artworkData: Data?
        let position: TimeInterval?
        let duration: TimeInterval?
        let playbackRate: Double
    }

    private func fetchSystemNowPlaying(excludingSpotifyIfPresent: Bool) async -> NowPlayingItem? {
        guard MediaRemoteBridge.isAvailable else { return nil }

        let snapshot: MediaRemoteSnapshot? = await Task.detached(priority: .utility) {
            // Fetch sequentially on the utility queue — still off main; avoids Sendable bridging of CF dicts.
            guard let info = MediaRemoteBridge.fetchNowPlayingInfoSync() else { return nil }
            let pid = MediaRemoteBridge.fetchApplicationPIDSync()
            let isPlaying = MediaRemoteBridge.fetchIsPlayingSync()

            let title = MediaRemoteKeys.stringValue(info, keys: [
                "kMRMediaRemoteNowPlayingInfoTitle", "Title", "title"
            ])
            let artist = MediaRemoteKeys.stringValue(info, keys: [
                "kMRMediaRemoteNowPlayingInfoArtist", "Artist", "artist"
            ])
            let album = MediaRemoteKeys.stringValue(info, keys: [
                "kMRMediaRemoteNowPlayingInfoAlbum", "Album", "album"
            ])
            guard !title.isEmpty || !artist.isEmpty else { return nil }

            let duration = MediaRemoteKeys.timeValue(info, keys: [
                "kMRMediaRemoteNowPlayingInfoDuration", "Duration", "duration"
            ])
            let elapsed = MediaRemoteKeys.timeValue(info, keys: [
                "kMRMediaRemoteNowPlayingInfoElapsedTime", "ElapsedTime", "elapsedTime"
            ])
            let rate = MediaRemoteKeys.doubleValue(info, keys: [
                "kMRMediaRemoteNowPlayingInfoPlaybackRate", "PlaybackRate", "playbackRate"
            ]) ?? (isPlaying ? 1 : 0)

            return MediaRemoteSnapshot(
                title: title,
                artist: artist,
                album: album,
                isPlaying: isPlaying,
                pid: pid,
                artworkData: MediaRemoteKeys.artworkData(from: info),
                position: elapsed,
                duration: duration,
                playbackRate: rate
            )
        }.value

        guard let snapshot else { return nil }

        var appName = "Now Playing"
        var bundleID: String?
        var icon: NSImage?

        if let pid = snapshot.pid, let app = NSRunningApplication(processIdentifier: pid) {
            appName = app.localizedName ?? appName
            bundleID = app.bundleIdentifier
            icon = app.icon

            if excludingSpotifyIfPresent,
               bundleID == SpotifyController.bundleID || appName.localizedCaseInsensitiveContains("spotify") {
                return nil
            }
        }

        let displayName = friendlyAppName(appName: appName, bundleID: bundleID)

        var artwork: NSImage?
        if let data = snapshot.artworkData {
            let key = "\(data.count)-\(data.prefix(32).hashValue)"
            if let cached = systemArtCache[key] {
                artwork = cached
            } else if let img = NSImage(data: data) {
                systemArtCache[key] = img
                artwork = img
                // Cap cache size
                if systemArtCache.count > 24 {
                    systemArtCache.removeAll(keepingCapacity: true)
                }
            }
        }

        let hasProgress = (snapshot.duration ?? 0) > 0.5 && snapshot.position != nil

        return NowPlayingItem(
            id: "system-\(bundleID ?? "unknown")",
            source: .system,
            appName: displayName,
            bundleID: bundleID,
            title: snapshot.title.isEmpty ? "Unknown title" : snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            isPlaying: snapshot.isPlaying,
            artwork: artwork,
            appIcon: icon,
            position: hasProgress ? snapshot.position : nil,
            duration: hasProgress ? snapshot.duration : nil,
            playbackRate: snapshot.isPlaying ? max(snapshot.playbackRate, 0.01) : 0,
            progressSampledAt: .now,
            canSeek: hasProgress
        )
    }

    private func friendlyAppName(appName: String, bundleID: String?) -> String {
        let id = bundleID ?? ""
        if id.contains("chrome") || appName.localizedCaseInsensitiveContains("chrome") { return "Chrome" }
        if id.contains("safari") || appName.localizedCaseInsensitiveContains("safari") { return "Safari" }
        if id.contains("firefox") || appName.localizedCaseInsensitiveContains("firefox") { return "Firefox" }
        if id.contains("//microsoft.edgemac") || appName.localizedCaseInsensitiveContains("edge") { return "Edge" }
        if id.contains("arc") || appName.localizedCaseInsensitiveContains("arc") { return "Arc" }
        if id.contains("brave") { return "Brave" }
        if id.contains("music") { return "Music" }
        return appName
    }

    private func downloadImage(_ url: URL) async -> NSImage? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return NSImage(data: data)
        } catch {
            log.debug("artwork fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

// MARK: - MediaRemote dictionary helpers

private enum MediaRemoteKeys {
    nonisolated static func stringValue(_ info: NSDictionary, keys: [String]) -> String {
        for key in keys {
            if let s = info[key] as? String, !s.isEmpty { return s }
        }
        for (k, v) in info {
            guard let s = v as? String, !s.isEmpty else { continue }
            let key = String(describing: k)
            for needle in keys {
                let short = needle.replacingOccurrences(of: "kMRMediaRemoteNowPlayingInfo", with: "")
                if key.localizedCaseInsensitiveContains(needle)
                    || (!short.isEmpty && key.localizedCaseInsensitiveContains(short)) {
                    return s
                }
            }
            if keys.contains(where: {
                key.hasSuffix($0.replacingOccurrences(of: "kMRMediaRemoteNowPlayingInfo", with: ""))
            }) {
                return s
            }
        }
        return ""
    }

    nonisolated static func timeValue(_ info: NSDictionary, keys: [String]) -> TimeInterval? {
        doubleValue(info, keys: keys)
    }

    nonisolated static func doubleValue(_ info: NSDictionary, keys: [String]) -> Double? {
        for key in keys {
            if let n = numeric(info[key]) { return n }
        }
        for (k, v) in info {
            let key = String(describing: k)
            for needle in keys {
                let short = needle.replacingOccurrences(of: "kMRMediaRemoteNowPlayingInfo", with: "")
                if key.localizedCaseInsensitiveContains(needle)
                    || (!short.isEmpty && key.localizedCaseInsensitiveContains(short)) {
                    if let n = numeric(v) { return n }
                }
            }
        }
        return nil
    }

    nonisolated private static func numeric(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String, let d = Double(s.replacingOccurrences(of: ",", with: ".")) {
            return d
        }
        return nil
    }

    nonisolated static func artworkData(from info: NSDictionary) -> Data? {
        for (k, v) in info {
            guard let d = v as? Data, d.count > 64 else { continue }
            let key = String(describing: k).lowercased()
            if key.contains("artwork") || key.contains("art") {
                return d
            }
        }
        return nil
    }
}
