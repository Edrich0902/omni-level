import Foundation

/// Loads built-in and user EQ presets from Application Support / bundle.
public final class PresetStore: ObservableObject {
    @Published public private(set) var presets: [EQPreset] = []
    @Published public var selectedPresetID: UUID?

    private let fileManager = FileManager.default
    private var userPresetsURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("OmniLevel/Presets", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("user-presets.json")
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
        // Merge any bundled JSON presets.
        if let bundled = loadBundledJSONPresets() {
            for p in bundled where !all.contains(where: { $0.name == p.name && $0.isBuiltIn }) {
                all.append(p)
            }
        }
        presets = all
        if selectedPresetID == nil {
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
    }

    public func deleteUserPreset(id: UUID) {
        var user = loadUserPresets()
        user.removeAll { $0.id == id }
        persistUserPresets(user)
        reload()
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
            // Also try flat resources
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
