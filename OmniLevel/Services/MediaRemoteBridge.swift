import AppKit
import Foundation

/// Soft-loads private MediaRemote symbols, with a bundled adapter fallback for macOS 15.4+
/// where in-process MediaRemote is entitlement-blocked (Spotify still works via AppleScript).
enum MediaRemoteBridge {
    enum Command: UInt32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
        /// Absolute seek (seconds) via options dictionary.
        case changePlaybackPosition = 47
    }

    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? = {
        dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_LAZY
        )
    }()

    private static func sym<T>(_ name: String) -> T? {
        guard let handle else { return nil }
        guard let ptr = dlsym(handle, name) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }

    static var isAvailable: Bool {
        handle != nil || MediaRemoteAdapterClient.isBundled
    }

    private typealias GetInfoFn = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) (CFDictionary?) -> Void
    ) -> Void

    private typealias SendCommandFn = @convention(c) (UInt32, CFDictionary?) -> Bool

    private typealias GetAppPIDFn = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) (Int32) -> Void
    ) -> Void

    private typealias GetIsPlayingFn = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) (Bool) -> Void
    ) -> Void

    /// Blocking fetch. Prefers direct MediaRemote; falls back to the perl adapter on nil.
    static func fetchNowPlayingInfoSync() -> NSDictionary? {
        if let direct = fetchNowPlayingInfoDirect(), direct.count > 0 {
            return direct
        }
        if let adapted = MediaRemoteAdapterClient.fetchNowPlaying(includeArtwork: false) {
            return adapted as NSDictionary
        }
        return nil
    }

    private static func fetchNowPlayingInfoDirect() -> NSDictionary? {
        guard let fn: GetInfoFn = sym("MRMediaRemoteGetNowPlayingInfo") else { return nil }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: NSDictionary?
        fn(DispatchQueue.global(qos: .userInitiated)) { dict in
            if let dict {
                result = dict as NSDictionary
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 0.6)
        return result
    }

    static func fetchApplicationPIDSync() -> pid_t? {
        if let fn: GetAppPIDFn = sym("MRMediaRemoteGetNowPlayingApplicationPID") {
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result: pid_t?
            fn(DispatchQueue.global(qos: .userInitiated)) { pid in
                result = pid == 0 ? nil : pid_t(pid)
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 0.4)
            if let result { return result }
        }
        // Adapter payload may include processIdentifier.
        if let dict = MediaRemoteAdapterClient.fetchNowPlaying(includeArtwork: false) {
            if let n = dict["processIdentifier"] as? NSNumber { return pid_t(n.int32Value) }
            if let i = dict["processIdentifier"] as? Int { return pid_t(i) }
        }
        return nil
    }

    static func fetchIsPlayingSync() -> Bool {
        if let fn: GetIsPlayingFn = sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result = false
            fn(DispatchQueue.global(qos: .userInitiated)) { playing in
                result = playing
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 0.4)
            // If direct returned true, trust it; if false, still check adapter
            // (direct often lies / returns default false when blocked).
            if result { return true }
        }
        if let dict = MediaRemoteAdapterClient.fetchNowPlaying(includeArtwork: false) {
            if let b = dict["playing"] as? Bool { return b }
            if let n = dict["playing"] as? NSNumber { return n.boolValue }
        }
        return false
    }

    @discardableResult
    static func send(_ command: Command) -> Bool {
        if let fn: SendCommandFn = sym("MRMediaRemoteSendCommand"),
           fn(command.rawValue, nil) {
            return true
        }
        return MediaRemoteAdapterClient.send(commandID: command.rawValue)
    }

    /// Seek to an absolute timeline position in seconds (best-effort).
    @discardableResult
    static func seek(to seconds: TimeInterval) -> Bool {
        if let fn: SendCommandFn = sym("MRMediaRemoteSendCommand") {
            let options: NSDictionary = [
                "kMRMediaRemoteOptionPlaybackPosition": seconds as NSNumber,
                "MRMediaRemoteOptionPlaybackPosition": seconds as NSNumber
            ]
            if fn(Command.changePlaybackPosition.rawValue, options as CFDictionary) {
                return true
            }
        }
        return MediaRemoteAdapterClient.seek(toSeconds: seconds)
    }
}
