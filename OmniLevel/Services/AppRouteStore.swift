import Foundation
import os

/// Persists per-app output routing as `bundleID → outputDeviceUID`.
/// Missing / nil UID → System Default (current global selected output).
@MainActor
public final class AppRouteStore: ObservableObject {
    /// bundleID → device UID (empty string is treated as System Default and stripped).
    @Published public private(set) var routes: [String: String] = [:]

    private let fileManager = FileManager.default
    private let log = Logger(subsystem: "com.omnilevel.app", category: "appRoute")

    private var fileURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("OmniLevel", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app-routes.json")
    }

    public init() {
        load()
    }

    public func outputDeviceUID(forBundleID bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let uid = routes[bundleID]
        guard let uid, !uid.isEmpty else { return nil }
        return uid
    }

    public func setOutputDeviceUID(_ uid: String?, forBundleID bundleID: String) {
        guard !bundleID.isEmpty else { return }
        if let uid, !uid.isEmpty {
            routes[bundleID] = uid
        } else {
            routes.removeValue(forKey: bundleID)
        }
        persist()
    }

    public func clearRoute(forBundleID bundleID: String) {
        setOutputDeviceUID(nil, forBundleID: bundleID)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoded = try JSONDecoder().decode([String: String].self, from: data)
            routes = decoded.filter { !$0.key.isEmpty && !$0.value.isEmpty }
            log.info("loaded \(self.routes.count) app output routes")
        } catch {
            log.error("load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(routes)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
