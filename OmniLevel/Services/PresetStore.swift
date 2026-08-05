import Foundation
import os

/// Durable EQ session storage (UserDefaults + Application Support).
/// Uses property-list friendly Doubles so values always round-trip.
public enum EQSessionStorage {
    private static let defaultsKey = "omniLevel.eqSession.v2"
    private static let selectedIDKey = "omniLevel.selectedPresetID"
    private static let log = Logger(subsystem: "com.omnilevel.app", category: "eqSession")

    private static var sessionFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("OmniLevel/Presets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-session.json")
    }

    public static func load() -> EQSessionState? {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let session = decode(data) {
            return session
        }
        // Migrate v1 if present.
        if let data = UserDefaults.standard.data(forKey: "omniLevel.lastEQSession.v1"),
           let session = decode(data) {
            save(session)
            return session
        }
        if let data = try? Data(contentsOf: sessionFileURL),
           let session = decode(data) {
            save(session) // refresh UserDefaults
            return session
        }
        return nil
    }

    public static func save(_ session: EQSessionState) {
        guard session.gainsdB.count == EqualizerDSP.bandCount else {
            log.error("reject session: gains=\(session.gainsdB.count)")
            return
        }
        guard let data = try? JSONEncoder().encode(session) else {
            log.error("encode failed")
            return
        }

        UserDefaults.standard.set(data, forKey: defaultsKey)
        // Also store simple fields for robustness / debugging.
        UserDefaults.standard.set(session.name, forKey: "omniLevel.eqName")
        UserDefaults.standard.set(session.gainsdB.map { Double($0) }, forKey: "omniLevel.eqGains")
        UserDefaults.standard.set(session.autoPreAmpEnabled, forKey: "omniLevel.eqAutoPreAmp")
        if let id = session.presetID {
            UserDefaults.standard.set(id.uuidString, forKey: selectedIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedIDKey)
        }
        UserDefaults.standard.synchronize()

        do {
            try data.write(to: sessionFileURL, options: .atomic)
            log.info("saved EQ session “\(session.name, privacy: .public)” autoPreAmp=\(session.autoPreAmpEnabled)")
        } catch {
            log.error("file write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func decode(_ data: Data) -> EQSessionState? {
        guard var session = try? JSONDecoder().decode(EQSessionState.self, from: data),
              session.gainsdB.count == EqualizerDSP.bandCount else {
            return nil
        }
        // Legacy encode sometimes stored auto pre-amp on by accident; keep explicit flag.
        return session
    }
}

/// Loads built-in and user EQ presets from Application Support / bundle.
public final class PresetStore: ObservableObject {
    @Published public private(set) var presets: [EQPreset] = []
    @Published public private(set) var selectedPresetID: UUID?

    private let fileManager = FileManager.default

    private var supportDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("OmniLevel/Presets", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var userPresetsURL: URL {
        supportDirectory.appendingPathComponent("user-presets.json")
    }

    public init() {
        reload()
    }

    public func reload() {
        var all = EQPreset.builtIn
        if let data = try? Data(contentsOf: userPresetsURL),
           let user = try? JSONDecoder().decode([EQPreset].self, from: data) {
            all.append(contentsOf: user)
        }
        if let bundled = loadBundledJSONPresets() {
            for p in bundled where !all.contains(where: { $0.name == p.name && $0.isBuiltIn }) {
                all.append(p)
            }
        }
        presets = all

        if let session = EQSessionStorage.load(),
           let id = session.presetID,
           all.contains(where: { $0.id == id }) {
            selectedPresetID = id
        } else if let raw = UserDefaults.standard.string(forKey: "omniLevel.selectedPresetID"),
                  let id = UUID(uuidString: raw),
                  all.contains(where: { $0.id == id }) {
            selectedPresetID = id
        } else {
            selectedPresetID = all.first?.id
        }
    }

    public func preset(id: UUID?) -> EQPreset? {
        guard let id else { return nil }
        return presets.first { $0.id == id }
    }

    public func saveUserPreset(name: String, gainsdB: [Float], qFactors: [Float]? = nil) {
        var user = loadUserPresets()
        let preset = EQPreset(name: name, gainsdB: gainsdB, qFactors: qFactors, isBuiltIn: false)
        user.append(preset)
        persistUserPresets(user)
        reload()
        selectedPresetID = preset.id
        EQSessionStorage.save(
            EQSessionState(
                name: name,
                presetID: preset.id,
                gainsdB: gainsdB,
                qFactors: qFactors,
                autoPreAmpEnabled: false
            )
        )
    }

    public func deleteUserPreset(id: UUID) {
        var user = loadUserPresets()
        user.removeAll { $0.id == id }
        persistUserPresets(user)
        reload()
        if selectedPresetID == id {
            selectedPresetID = EQPreset.builtIn.first?.id
        }
    }

    /// Writes the live EQ session (called from EqualizerViewModel).
    public func saveSession(_ session: EQSessionState) {
        EQSessionStorage.save(session)
        if let id = session.presetID, presets.contains(where: { $0.id == id }) {
            selectedPresetID = id
        } else if session.name == "Custom" || !presets.contains(where: { $0.name == session.name }) {
            // Keep preset list selection only when it matches a known preset.
        }
    }

    public func loadSession() -> EQSessionState? {
        EQSessionStorage.load()
    }

    private func loadUserPresets() -> [EQPreset] {
        guard let data = try? Data(contentsOf: userPresetsURL),
              let decoded = try? JSONDecoder().decode([EQPreset].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persistUserPresets(_ presets: [EQPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: userPresetsURL, options: .atomic)
    }

    private func loadBundledJSONPresets() -> [EQPreset]? {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "Presets") else {
            if let url = Bundle.main.url(forResource: "flat", withExtension: "json") {
                return loadPresetFile(url)
            }
            return nil
        }
        return urls.flatMap { loadPresetFile($0) ?? [] }
    }

    private func loadPresetFile(_ url: URL) -> [EQPreset]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let one = try? JSONDecoder().decode(EQPreset.self, from: data) {
            return [one]
        }
        if let many = try? JSONDecoder().decode([EQPreset].self, from: data) {
            return many
        }
        return nil
    }
}
