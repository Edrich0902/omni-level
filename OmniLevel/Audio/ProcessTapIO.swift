import CoreAudio
import Foundation
import os

/// Core Audio process taps (macOS 14.2+).
///
/// Two modes:
/// - **Per-app** stereo mixdown taps (one process each) so volume / balance can be applied
/// - Private **tap-only** aggregates used as capture devices (output stays on the real speakers)
public final class ProcessTapIO: @unchecked Sendable {
    public struct AppTapHandle: Sendable {
        public let pid: pid_t
        public let tapID: AudioObjectID
        public let aggregateDeviceID: AudioObjectID
        public let tapUID: String
    }

    public enum TapError: Error, LocalizedError {
        case createTapFailed(OSStatus)
        case createAggregateFailed(OSStatus)
        case tapUIDUnavailable
        case noProcessTapsCreated
        case unavailable

        public var errorDescription: String? {
            switch self {
            case .createTapFailed(let status):
                return "Failed to create process tap (OSStatus \(status))"
            case .createAggregateFailed(let status):
                return "Failed to create aggregate device (OSStatus \(status))"
            case .tapUIDUnavailable:
                return "Could not read process tap UID"
            case .noProcessTapsCreated:
                return "Could not create any app process taps"
            case .unavailable:
                return "Process taps require macOS 14.2 or later"
            }
        }
    }

    private let lock = OSAllocatedUnfairLock()
    private var appTaps: [AppTapHandle] = []

    public init() {}

    deinit {
        destroyAllAppTaps()
    }

    public func currentAppTaps() -> [AppTapHandle] {
        lock.withLock { appTaps }
    }

    /// Create one muted-when-tapped stereo mixdown tap per PID (full replace).
    @available(macOS 14.2, *)
    @discardableResult
    public func startAppTaps(pids: [pid_t]) throws -> [AppTapHandle] {
        try syncAppTaps(pids: pids)
    }

    /// Differential: destroy taps for removed PIDs, create only for new ones.
    /// Surviving taps stay live so audio through those apps is uninterrupted.
    @available(macOS 14.2, *)
    @discardableResult
    public func syncAppTaps(pids: [pid_t]) throws -> [AppTapHandle] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let desired = Set(pids.filter { $0 != ownPID })

        let existing = lock.withLock { appTaps }
        let existingByPID = Dictionary(uniqueKeysWithValues: existing.map { ($0.pid, $0) })
        let currentPIDs = Set(existingByPID.keys)

        let toRemove = currentPIDs.subtracting(desired)
        let toAdd = desired.subtracting(currentPIDs)

        // Destroy removed taps first (releases mute-when-tapped for those apps only).
        for pid in toRemove {
            if let handle = existingByPID[pid] {
                destroy(handle: handle)
            }
        }

        var kept = existing.filter { desired.contains($0.pid) }
        for pid in toAdd {
            if let handle = try createAppTap(pid: pid) {
                kept.append(handle)
            }
        }

        // Stable order by PID for deterministic mix.
        kept.sort { $0.pid < $1.pid }

        if kept.isEmpty, !desired.isEmpty {
            throw TapError.noProcessTapsCreated
        }

        let snapshot = kept
        lock.withLock { appTaps = snapshot }
        return snapshot
    }

    public func destroyAllAppTaps() {
        let handles: [AppTapHandle] = lock.withLock {
            let h = appTaps
            appTaps = []
            return h
        }
        for handle in handles {
            destroy(handle: handle)
        }
    }

    private func destroy(handle: AppTapHandle) {
        if handle.aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(handle.aggregateDeviceID)
        }
        if #available(macOS 14.2, *), handle.tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(handle.tapID)
        }
    }

    @available(macOS 14.2, *)
    private func createAppTap(pid: pid_t) throws -> AppTapHandle? {
        guard let processObject = Self.audioProcessObjectID(for: pid) else { return nil }

        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.name = "OmniLevel App \(pid)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else { return nil }

        guard let uid = Self.tapUID(for: tapID) else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        do {
            let aggregateID = try Self.createTapOnlyAggregate(tapUID: uid, label: "App\(pid)")
            return AppTapHandle(
                pid: pid,
                tapID: tapID,
                aggregateDeviceID: aggregateID,
                tapUID: uid
            )
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
    }

    // MARK: - CoreAudio helpers

    public static func audioProcessObjectID(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var qualifier = pid
        let status = withUnsafePointer(to: &qualifier) { qualPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                qualPtr,
                &size,
                &processObject
            )
        }

        if status == noErr, processObject != kAudioObjectUnknown {
            return processObject
        }
        return findProcessObjectByEnumerating(pid: pid)
    }

    private static func findProcessObjectByEnumerating(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processes = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &processes
        ) == noErr else { return nil }

        for processID in processes {
            var processPID: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(processID, &pidAddress, 0, nil, &pidSize, &processPID) == noErr,
               processPID == pid {
                return processID
            }
        }
        return nil
    }

    public static func tapUID(for tapID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var uidRef: CFString?
        let status = withUnsafeMutablePointer(to: &uidRef) { ptr in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, ptr)
        }
        if status == noErr, let uidRef {
            return uidRef as String
        }
        return nil
    }

    public static func deviceUID(for deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var uidRef: CFString?
        let status = withUnsafeMutablePointer(to: &uidRef) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
        }
        if status == noErr, let uidRef {
            return uidRef as String
        }
        return nil
    }

    @available(macOS 14.2, *)
    private static func createTapOnlyAggregate(tapUID: String, label: String) throws -> AudioObjectID {
        let aggregateUID = "OmniLevel.Agg.\(label).\(UUID().uuidString)"

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OmniLevel \(label)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ] as [String: Any]
            ]
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            throw TapError.createAggregateFailed(status)
        }
        return aggregateID
    }

    public static func defaultOutputDeviceID() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return deviceID
    }

    public static func deviceSampleRate(_ deviceID: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 48_000
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return rate
    }

    public static func deviceChannelCount(_ deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        var total = 0
        for buffer in abl {
            total += Int(buffer.mNumberChannels)
        }
        return total
    }
}
