import Foundation
import os

/// Per-app EQ curve persisted in Application Support, keyed by bundle ID.
/// Missing key → app uses the global equalizer. Present → override for that app’s stream only.
@MainActor
public final class PerAppEQStore: ObservableObject {
    public struct Entry: Codable, Equatable, Sendable {
        public var gainsdB: [Float]
        public var qFactors: [Float]?
        public var name: String?
        public var updatedAt: TimeInterval

        public init(
            gainsdB: [Float],
            qFactors: [Float]? = nil,
            name: String? = nil,
            updatedAt: TimeInterval = Date().timeIntervalSinceReferenceDate
        ) {
            self.gainsdB = gainsdB
            self.qFactors = qFactors
            self.name = name
            self.updatedAt = updatedAt
        }
    }

    @Published public private(set) var entries: [String: Entry] = [:]

    private let fileManager = FileManager.default
    private let log = Logger(subsystem: "com.omnilevel.app", category: "perAppEQ")

    private var fileURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("OmniLevel", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("per-app-eq.json")
    }

    public init() {
        load()
    }

    public var overrideCount: Int { entries.count }

    public func entry(forBundleID bundleID: String?) -> Entry? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return entries[bundleID]
    }

    public func hasOverride(forBundleID bundleID: String?) -> Bool {
        entry(forBundleID: bundleID) != nil
    }

    public func setOverride(
        bundleID: String,
        gainsdB: [Float],
        qFactors: [Float]? = nil,
        name: String? = nil
    ) {
        guard !bundleID.isEmpty, gainsdB.count == EqualizerDSP.bandCount else { return }
        var qs = qFactors
        if let q = qs, q.count != EqualizerDSP.bandCount { qs = nil }
        entries[bundleID] = Entry(
            gainsdB: gainsdB,
            qFactors: qs,
            name: name,
            updatedAt: Date().timeIntervalSinceReferenceDate
        )
        persist()
    }

    public func removeOverride(bundleID: String) {
        guard entries.removeValue(forKey: bundleID) != nil else { return }
        persist()
    }

    public func allBundleIDs() -> [String] {
        Array(entries.keys).sorted()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoded = try JSONDecoder().decode([String: Entry].self, from: data)
            entries = decoded.filter { $0.value.gainsdB.count == EqualizerDSP.bandCount }
            log.info("loaded \(self.entries.count) per-app EQ overrides")
        } catch {
            log.error("load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
