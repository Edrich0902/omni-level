import AppKit
import Foundation

/// Soft-loads private MediaRemote symbols for system Now Playing (browsers, Music, …).
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

    static var isAvailable: Bool { handle != nil }

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

    /// Blocking fetch on a background queue (call off main if needed).
    static func fetchNowPlayingInfoSync() -> NSDictionary? {
        guard let fn: GetInfoFn = sym("MRMediaRemoteGetNowPlayingInfo") else { return nil }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: NSDictionary?
        fn(DispatchQueue.global(qos: .userInitiated)) { dict in
            if let dict {
                result = dict as NSDictionary
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 1.5)
        return result
    }

    static func fetchApplicationPIDSync() -> pid_t? {
        guard let fn: GetAppPIDFn = sym("MRMediaRemoteGetNowPlayingApplicationPID") else { return nil }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: pid_t?
        fn(DispatchQueue.global(qos: .userInitiated)) { pid in
            result = pid == 0 ? nil : pid_t(pid)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 1.0)
        return result
    }

    static func fetchIsPlayingSync() -> Bool {
        guard let fn: GetIsPlayingFn = sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying") else {
            return false
        }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = false
        fn(DispatchQueue.global(qos: .userInitiated)) { playing in
            result = playing
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 1.0)
        return result
    }

    @discardableResult
    static func send(_ command: Command) -> Bool {
        guard let fn: SendCommandFn = sym("MRMediaRemoteSendCommand") else { return false }
        return fn(command.rawValue, nil)
    }

    /// Seek to an absolute timeline position in seconds (best-effort private API).
    @discardableResult
    static func seek(to seconds: TimeInterval) -> Bool {
        guard let fn: SendCommandFn = sym("MRMediaRemoteSendCommand") else { return false }
        let options: NSDictionary = [
            "kMRMediaRemoteOptionPlaybackPosition": seconds as NSNumber,
            "MRMediaRemoteOptionPlaybackPosition": seconds as NSNumber
        ]
        return fn(Command.changePlaybackPosition.rawValue, options as CFDictionary)
    }
}
