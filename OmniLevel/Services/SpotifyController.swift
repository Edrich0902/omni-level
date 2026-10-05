import AppKit
import Foundation

/// Spotify Desktop via AppleScript — dedicated path so it stays controllable even
/// when another app owns system Media Remote (e.g. a browser tab).
enum SpotifyController {
    static let bundleID = "com.spotify.client"

    struct State {
        var title: String
        var artist: String
        var album: String
        var artworkURL: String?
        var isPlaying: Bool
        /// Seconds into the current track.
        var position: TimeInterval
        /// Track length in seconds.
        var duration: TimeInterval
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func appIcon() -> NSImage? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
    }

    private static let fetchSource = """
    tell application "Spotify"
        if not running then return ""
        set US to ASCII character 31
        set t to name of current track
        set a to artist of current track
        set al to album of current track
        set art to artwork url of current track
        set p to player state as string
        set pos to player position
        set dur to duration of current track
        return t & US & a & US & al & US & art & US & p & US & pos & US & dur
    end tell
    """

    /// Compiled once — recompiling the poll script every cycle was a steady CPU cost.
    /// NSAppleScript is not thread-safe, so all use goes through `fetchLock`.
    nonisolated(unsafe) private static var compiledFetch: NSAppleScript?
    private static let fetchLock = NSLock()

    /// Returns track metadata if Spotify is running.
    static func fetchState() -> State? {
        guard isRunning else { return nil }

        let raw: String? = fetchLock.withLock {
            if compiledFetch == nil {
                let script = NSAppleScript(source: fetchSource)
                var error: NSDictionary?
                if script?.compileAndReturnError(&error) == true {
                    compiledFetch = script
                }
            }
            guard let script = compiledFetch else { return nil }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            return error == nil ? result.stringValue : nil
        }
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "\u{001F}")
        guard parts.count >= 7 else { return nil }

        let title = parts[0]
        let artist = parts[1]
        let album = parts[2]
        let art = parts[3]
        let state = parts[4].lowercased()
        if title.isEmpty && artist.isEmpty { return nil }

        let position = TimeInterval(parts[5].replacingOccurrences(of: ",", with: ".")) ?? 0
        let durationRaw = TimeInterval(parts[6].replacingOccurrences(of: ",", with: ".")) ?? 0
        let duration = durationRaw > 10_000 ? durationRaw / 1000.0 : durationRaw

        return State(
            title: title,
            artist: artist,
            album: album,
            artworkURL: art.isEmpty ? nil : art,
            isPlaying: state.contains("playing"),
            position: max(0, position),
            duration: max(0, duration)
        )
    }

    static func togglePlayPause() { runAppleScript("tell application \"Spotify\" to playpause") }
    static func nextTrack() { runAppleScript("tell application \"Spotify\" to next track") }
    static func previousTrack() { runAppleScript("tell application \"Spotify\" to previous track") }

    static func setPosition(_ seconds: TimeInterval) {
        let clamped = max(0, seconds)
        runAppleScript("tell application \"Spotify\" to set player position to \(clamped)")
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }
}
