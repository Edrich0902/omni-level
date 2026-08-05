import CoreAudio
import Foundation

public struct AudioDeviceInfo: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let name: String
    public let uid: String
    public let hasInput: Bool
    public let hasOutput: Bool

    public var displayName: String { name }
}
