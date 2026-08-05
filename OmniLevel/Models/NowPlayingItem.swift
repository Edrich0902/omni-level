import AppKit
import Foundation

/// Snapshot of one controllable now-playing source.
struct NowPlayingItem: Identifiable, Equatable {
    enum SourceKind: String, Equatable {
        case spotify
        case system   // Media Remote (browsers, Music, etc.)
    }

    let id: String
    let source: SourceKind
    var appName: String
    var bundleID: String?
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var artwork: NSImage?
    var appIcon: NSImage?

    /// Playback position in seconds at `progressSampledAt`.
    var position: TimeInterval?
    /// Track length in seconds.
    var duration: TimeInterval?
    /// Effective rate when playing (usually 1). 0 when paused.
    var playbackRate: Double
    /// Wall-clock sample time for interpolating live position.
    var progressSampledAt: Date
    /// Remote supports seeking when duration is known.
    var canSeek: Bool

    var subtitle: String {
        [artist, album].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var hasProgress: Bool {
        guard let duration, duration > 0.5 else { return false }
        return position != nil
    }

    /// Live position (advances while playing between poll cycles).
    func livePosition(at date: Date = .now) -> TimeInterval {
        guard let position, let duration, duration > 0 else { return position ?? 0 }
        guard isPlaying, playbackRate > 0 else { return min(max(position, 0), duration) }
        let advanced = position + date.timeIntervalSince(progressSampledAt) * playbackRate
        return min(max(advanced, 0), duration)
    }

    func progressFraction(at date: Date = .now) -> Double {
        guard let duration, duration > 0 else { return 0 }
        return min(max(livePosition(at: date) / duration, 0), 1)
    }

    static func empty(source: SourceKind, appName: String, id: String) -> NowPlayingItem {
        NowPlayingItem(
            id: id,
            source: source,
            appName: appName,
            bundleID: nil,
            title: "Not playing",
            artist: "",
            album: "",
            isPlaying: false,
            artwork: nil,
            appIcon: nil,
            position: nil,
            duration: nil,
            playbackRate: 0,
            progressSampledAt: .now,
            canSeek: false
        )
    }
}
