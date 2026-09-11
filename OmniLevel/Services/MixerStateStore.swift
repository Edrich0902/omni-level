import Foundation
import os

/// Persists per-app mixer controls + master bypass in Application Support, keyed by bundle ID.
@MainActor
public final class MixerStateStore: ObservableObject {
    public struct AppEntry: Codable, Equatable, Sendable {
        public var volume: Float
        public var pan: Float
        public var isMuted: Bool
        public var isSolo: Bool
        public var bypassed: Bool

        public init(
            volume: Float = 1,
            pan: Float = 0,
            isMuted: Bool = false,
            isSolo: Bool = false,
            bypassed: Bool = false
        ) {
            self.volume = volume
            self.pan = pan
            self.isMuted = isMuted
            self.isSolo = isSolo
            self.bypassed = bypassed
        }
    }

    private struct FilePayload: Codable {
        var isOmniLevelBypassed: Bool
        var apps: [String: AppEntry]
    }

    @Published public private(set) var apps: [String: AppEntry] = [:]
    @Published public private(set) var isOmniLevelBypassed: Bool = false

    private let fileManager = FileManager.default
    private let log = Logger(subsystem: "com.omnilevel.app", category: "mixerState")

    private var fileURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("OmniLevel", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mixer-state.json")
    }

    public init() {
        load()
    }

    public func entry(forBundleID bundleID: String?) -> AppEntry? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return apps[bundleID]
    }

    public func setMasterBypass(_ bypassed: Bool) {
        guard isOmniLevelBypassed != bypassed else { return }
        isOmniLevelBypassed = bypassed
        persist()
    }

    public func upsert(
        bundleID: String,
        volume: Float,
        pan: Float,
        isMuted: Bool,
        isSolo: Bool,
        bypassed: Bool
    ) {
        guard !bundleID.isEmpty else { return }
        let next = AppEntry(
            volume: max(0, min(2, volume)),
            pan: max(-1, min(1, pan)),
            isMuted: isMuted,
            isSolo: isSolo,
            bypassed: bypassed
        )
        if apps[bundleID] == next { return }
        apps[bundleID] = next
        persist()
    }

    /// Snapshot write used by debounced flush from the tap manager.
    public func replaceSnapshot(apps nextApps: [String: AppEntry], masterBypass: Bool) {
        let filtered = nextApps.filter { !$0.key.isEmpty }
        if filtered == apps, masterBypass == isOmniLevelBypassed { return }
        apps = filtered
        isOmniLevelBypassed = masterBypass
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoded = try JSONDecoder().decode(FilePayload.self, from: data)
            apps = decoded.apps.filter { !$0.key.isEmpty }
            isOmniLevelBypassed = decoded.isOmniLevelBypassed
            log.info("loaded mixer state for \(self.apps.count) apps bypass=\(self.isOmniLevelBypassed)")
        } catch {
            log.error("load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        let payload = FilePayload(isOmniLevelBypassed: isOmniLevelBypassed, apps: apps)
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
