import AppKit
import Foundation

public struct AppAudioNode: Identifiable, Equatable {
    public let id: pid_t
    public let appName: String
    public let bundleIdentifier: String?
    public let appIcon: NSImage
    public var volume: Float
    public var pan: Float
    public var isMuted: Bool
    public var isSolo: Bool
    public var isTapped: Bool
    public var peakLeveldB: Float
    /// True when this app has a stored per-app EQ curve (not using global).
    public var hasEQOverride: Bool
    /// Preferred output device UID; `nil` = System Default (global selected output).
    public var outputDeviceUID: String?
    /// True when the preferred device was unavailable and we fell back to System Default.
    public var outputFallback: Bool

    public init(
        id: pid_t,
        appName: String,
        bundleIdentifier: String?,
        appIcon: NSImage,
        volume: Float = 1.0,
        pan: Float = 0.0,
        isMuted: Bool = false,
        isSolo: Bool = false,
        isTapped: Bool = false,
        peakLeveldB: Float = -60,
        hasEQOverride: Bool = false,
        outputDeviceUID: String? = nil,
        outputFallback: Bool = false
    ) {
        self.id = id
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.appIcon = appIcon
        self.volume = volume
        self.pan = pan
        self.isMuted = isMuted
        self.isSolo = isSolo
        self.isTapped = isTapped
        self.peakLeveldB = peakLeveldB
        self.hasEQOverride = hasEQOverride
        self.outputDeviceUID = outputDeviceUID
        self.outputFallback = outputFallback
    }

    public var volumePercent: Int {
        Int((volume * 100).rounded())
    }

    public var volumeDecibels: Float {
        guard volume > 0.0001 else { return -60 }
        return 20 * log10(volume)
    }
}
