import AppKit
import Foundation
import os

/// Invokes the bundled MediaRemote Adapter (perl + helper framework) so Now Playing
/// works on macOS 15.4+ where in-process MediaRemote returns nil.
enum MediaRemoteAdapterClient {
    private static let log = Logger(subsystem: "com.omnilevel.app", category: "mrAdapter")

    private static var scriptURL: URL? {
        Bundle.main.url(
            forResource: "mediaremote-adapter",
            withExtension: "pl",
            subdirectory: "MediaRemoteAdapter"
        )
    }

    private static var frameworkURL: URL? {
        Bundle.main.url(
            forResource: "MediaRemoteAdapter",
            withExtension: "framework",
            subdirectory: "MediaRemoteAdapter"
        )
    }

    static var isBundled: Bool {
        scriptURL != nil && frameworkURL != nil
    }

    /// One-shot Now Playing snapshot (JSON → dictionary). `null` JSON → nil.
    static func fetchNowPlaying(includeArtwork: Bool = false) -> [String: Any]? {
        var args = ["get"]
        if !includeArtwork { args.append("--no-artwork") }
        args.append("--now")
        guard let json = run(arguments: args) else { return nil }
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "null", !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    @discardableResult
    static func send(commandID: UInt32) -> Bool {
        run(arguments: ["send", "\(commandID)"]) != nil
    }

    /// Seek to absolute position in seconds (adapter expects microseconds).
    @discardableResult
    static func seek(toSeconds seconds: TimeInterval) -> Bool {
        let micros = max(0, Int((seconds * 1_000_000).rounded()))
        return run(arguments: ["seek", "\(micros)"]) != nil
    }

    @discardableResult
    private static func run(arguments: [String]) -> String? {
        guard let script = scriptURL, let framework = frameworkURL else {
            log.debug("MediaRemote adapter not bundled")
            return nil
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = [script.path, framework.path] + arguments
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            log.error("adapter launch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log.debug("adapter exit \(proc.terminationStatus): \(errText, privacy: .public)")
            return nil
        }
        return text
    }
}
