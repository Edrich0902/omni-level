import CoreAudio
import Foundation

/// Enumerates CoreAudio HAL devices and tracks user-selected I/O.
@MainActor
public final class AudioDeviceManager: ObservableObject {
    @Published public private(set) var devices: [AudioDeviceInfo] = []
    @Published public var selectedInputID: AudioObjectID = kAudioObjectUnknown
    @Published public var selectedOutputID: AudioObjectID = kAudioObjectUnknown

    public var inputDevices: [AudioDeviceInfo] {
        devices.filter(\.hasInput)
    }

    public var outputDevices: [AudioDeviceInfo] {
        devices.filter(\.hasOutput)
    }

    public init() {
        refresh()
    }

    public func refresh() {
        devices = Self.enumerateDevices()
        if selectedInputID == kAudioObjectUnknown || !devices.contains(where: { $0.id == selectedInputID && $0.hasInput }) {
            selectedInputID = Self.defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
        }
        if selectedOutputID == kAudioObjectUnknown || !devices.contains(where: { $0.id == selectedOutputID && $0.hasOutput }) {
            selectedOutputID = Self.defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        }
    }

    public func inputName() -> String {
        devices.first(where: { $0.id == selectedInputID })?.name ?? "Default Input"
    }

    public func outputName() -> String {
        devices.first(where: { $0.id == selectedOutputID })?.name ?? "Default Output"
    }

    // MARK: - CoreAudio

    private static func enumerateDevices() -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
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
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { id -> AudioDeviceInfo? in
            guard let name = deviceName(id) else { return nil }
            let uid = deviceUID(id) ?? "\(id)"
            let inCh = channelCount(id, scope: kAudioObjectPropertyScopeInput)
            let outCh = channelCount(id, scope: kAudioObjectPropertyScopeOutput)
            guard inCh > 0 || outCh > 0 else { return nil }
            return AudioDeviceInfo(
                id: id,
                name: name,
                uid: uid,
                hasInput: inCh > 0,
                hasOutput: outCh > 0
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func defaultDevice(selector: AudioObjectPropertySelector) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
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

    private static func deviceName(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let name else { return nil }
        return name as String
    }

    private static func deviceUID(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let uid else { return nil }
        return uid as String
    }

    private static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, raw) == noErr else { return 0 }
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        var total = 0
        for buffer in buffers {
            total += Int(buffer.mNumberChannels)
        }
        return total
    }
}
