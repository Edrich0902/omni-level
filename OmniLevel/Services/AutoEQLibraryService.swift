import Foundation
import os

/// Browse and download profiles from the public [AutoEq](https://github.com/jaakkopasanen/AutoEq) results library.
@MainActor
final class AutoEQLibraryService: ObservableObject {
    struct Entry: Identifiable, Hashable, Sendable {
        var id: String { "\(source)|\(path)" }
        let name: String
        /// Relative path under `results/` (decoded), e.g. `oratory1990/over-ear/Sennheiser HD 650`
        let path: String
        let source: String

        var formFactor: String {
            let lower = path.lowercased()
            if lower.contains("in-ear") { return "In-ear" }
            if lower.contains("over-ear") || lower.contains("over ear") { return "Over-ear" }
            if lower.contains("earbud") { return "Earbud" }
            return "Headphone"
        }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isLoadingIndex = false
    @Published private(set) var isLoadingProfile = false
    @Published private(set) var lastError: String?
    @Published var searchQuery: String = ""

    private let log = Logger(subsystem: "com.omnilevel.app", category: "autoeq")
    private let indexURL = URL(string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/INDEX.md")!
    private let rawBase = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("OmniLevel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("autoeq-index-cache.md")
    }

    func clearError() {
        lastError = nil
    }

    var filteredEntries: [Entry] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw: [Entry]
        if q.isEmpty {
            // Prefer well-known measurement sources when browsing unfiltered (keeps list manageable).
            raw = entries.filter {
                $0.source == "oratory1990" || $0.source == "crinacle" || $0.source == "Rtings"
            }
        } else {
            raw = entries.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                || $0.source.localizedCaseInsensitiveContains(q)
                || $0.path.localizedCaseInsensitiveContains(q)
            }
        }
        // Prefer oratory1990, then crinacle, when names collide.
        return raw.sorted { a, b in
            let ra = sourceRank(a.source)
            let rb = sourceRank(b.source)
            if ra != rb { return ra < rb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func ensureIndexLoaded() async {
        if !entries.isEmpty { return }
        // Try disk cache first for snappy UI.
        if let data = try? Data(contentsOf: cacheURL),
           let text = String(data: data, encoding: .utf8) {
            entries = Self.parseIndex(text)
        }
        await refreshIndex(force: entries.isEmpty)
    }

    func refreshIndex(force: Bool = true) async {
        if isLoadingIndex { return }
        if !force, !entries.isEmpty { return }
        isLoadingIndex = true
        lastError = nil
        defer { isLoadingIndex = false }

        do {
            let (data, response) = try await URLSession.shared.data(from: indexURL)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            try? data.write(to: cacheURL, options: .atomic)
            entries = Self.parseIndex(text)
            log.info("loaded AutoEQ index · \(self.entries.count) profiles")
        } catch {
            lastError = "Couldn’t load AutoEQ library: \(error.localizedDescription)"
            log.error("index load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func downloadProfile(_ entry: Entry) async throws -> AutoEQProfile {
        isLoadingProfile = true
        lastError = nil
        defer { isLoadingProfile = false }

        let leaf = (entry.path as NSString).lastPathComponent
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")

        let pathSegments = entry.path.split(separator: "/").map(String.init)
        let encodedDir = pathSegments
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
            .joined(separator: "/")
        let fileName = "\(leaf) ParametricEQ.txt"
        let encodedFile = fileName.addingPercentEncoding(withAllowedCharacters: allowed) ?? fileName

        guard let url = URL(string: rawBase + encodedDir + "/" + encodedFile) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw URLError(.cannotDecodeContentData)
        }
        let profile = AutoEQImporter.parse(text: text, name: entry.name)
        guard !profile.filters.isEmpty else {
            throw NSError(
                domain: "OmniLevel.AutoEQ",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No parametric filters found for \(entry.name)"]
            )
        }
        return profile
    }

    private func sourceRank(_ source: String) -> Int {
        switch source.lowercased() {
        case "oratory1990": return 0
        case "crinacle": return 1
        case "rtings": return 2
        default: return 5
        }
    }

    /// Lines like: `- [Sennheiser HD 650](./oratory1990/over-ear/Sennheiser%20HD%20650) by oratory1990`
    nonisolated static func parseIndex(_ markdown: String) -> [Entry] {
        var result: [Entry] = []
        result.reserveCapacity(8_000)
        for line in markdown.split(whereSeparator: \.isNewline) {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("- [") else { continue }
            guard let nameStart = s.firstIndex(of: "["),
                  let nameEnd = s.firstIndex(of: "]"),
                  nameStart < nameEnd
            else { continue }
            let name = String(s[s.index(after: nameStart)..<nameEnd])

            guard let pathStart = s.firstIndex(of: "("),
                  let pathEnd = s.firstIndex(of: ")"),
                  pathStart < pathEnd
            else { continue }
            var path = String(s[s.index(after: pathStart)..<pathEnd])
            if path.hasPrefix("./") { path.removeFirst(2) }
            path = path.removingPercentEncoding ?? path
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            var source = "unknown"
            if let byRange = s.range(of: " by ", options: .caseInsensitive) {
                source = String(s[byRange.upperBound...])
                    .components(separatedBy: " on ")
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? source
            } else if let slash = path.firstIndex(of: "/") {
                source = String(path[..<slash])
            }

            guard !name.isEmpty, !path.isEmpty else { continue }
            result.append(Entry(name: name, path: path, source: source))
        }
        return result
    }
}
