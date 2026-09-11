import Foundation
import os

/// Persists Apps-list organization (favorites, pin order, groups) keyed by bundle ID.
@MainActor
public final class AppListStore: ObservableObject {
    public struct Group: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var members: [String]

        public init(id: String = UUID().uuidString, name: String, members: [String] = []) {
            self.id = id
            self.name = name
            self.members = members
        }
    }

    public enum MoveDirection {
        case up
        case down
    }

    private struct FilePayload: Codable {
        var favorites: [String]
        var order: [String]
        var groups: [Group]
    }

    @Published public private(set) var favorites: [String] = []
    @Published public private(set) var order: [String] = []
    @Published public private(set) var groups: [Group] = []
    /// Bumped on every mutation so popover UI can force a refresh.
    @Published public private(set) var revision: UInt64 = 0

    private let fileManager = FileManager.default
    private let log = Logger(subsystem: "com.omnilevel.app", category: "appList")
    private var persistTask: Task<Void, Never>?

    private var fileURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("OmniLevel", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app-list.json")
    }

    public init() {
        load()
    }

    // MARK: - Queries

    public func isFavorite(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return favorites.contains(bundleID)
    }

    public func group(containing bundleID: String?) -> Group? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return groups.first { $0.members.contains(bundleID) }
    }

    public func orderIndex(for bundleID: String?) -> Int? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return order.firstIndex(of: bundleID)
    }

    /// Sort key: lower `order` index first; unknown IDs sort after known, then by name.
    public func compareForDisplay(_ a: String?, nameA: String, _ b: String?, nameB: String) -> Bool {
        let ia = orderIndex(for: a) ?? Int.max
        let ib = orderIndex(for: b) ?? Int.max
        if ia != ib { return ia < ib }
        return nameA.localizedCaseInsensitiveCompare(nameB) == .orderedAscending
    }

    // MARK: - Favorites

    public func setFavorite(_ favorite: Bool, bundleID: String?) {
        guard let bundleID, !bundleID.isEmpty else { return }
        if favorite {
            if !favorites.contains(bundleID) {
                favorites = favorites + [bundleID]
            }
            ensureInOrder(bundleID)
        } else {
            let next = favorites.filter { $0 != bundleID }
            if next != favorites { favorites = next }
        }
        schedulePersist()
    }

    public func toggleFavorite(bundleID: String?) {
        setFavorite(!isFavorite(bundleID: bundleID), bundleID: bundleID)
    }

    // MARK: - Order

    /// Move `bundleID` up/down among `peerBundleIDs` (section peers), persisting global `order`.
    public func move(bundleID: String?, amongPeers peerBundleIDs: [String], direction: MoveDirection) {
        guard let bundleID, !bundleID.isEmpty else { return }
        let peers = peerBundleIDs.filter { !$0.isEmpty }
        guard peers.count > 1, let idx = peers.firstIndex(of: bundleID) else { return }
        let swapIdx: Int
        switch direction {
        case .up:
            guard idx > 0 else { return }
            swapIdx = idx - 1
        case .down:
            guard idx + 1 < peers.count else { return }
            swapIdx = idx + 1
        }
        let other = peers[swapIdx]
        ensureInOrder(bundleID)
        ensureInOrder(other)
        guard let ai = order.firstIndex(of: bundleID),
              let bi = order.firstIndex(of: other) else { return }
        var next = order
        next.swapAt(ai, bi)
        order = next
        schedulePersist()
    }

    /// Reorder peers within a section (drag-and-drop). `orderedPeers` is the new peer sequence.
    public func applySectionOrder(_ orderedPeers: [String]) {
        let peers = orderedPeers.filter { !$0.isEmpty }
        guard !peers.isEmpty else { return }
        let peerSet = Set(peers)
        var next: [String] = []
        var inserted = false
        for id in order {
            if peerSet.contains(id) {
                if !inserted {
                    next.append(contentsOf: peers)
                    inserted = true
                }
            } else {
                next.append(id)
            }
        }
        if !inserted {
            next.append(contentsOf: peers)
        }
        for p in peers where !next.contains(p) {
            next.append(p)
        }
        guard next != order else {
            // Membership may have changed even if order array is identical.
            schedulePersist()
            return
        }
        order = next
        schedulePersist()
    }

    /// Place an app into Favorites, a group, or Other, optionally inserting before `beforeBundleID`.
    public func place(
        bundleID: String?,
        destination: PlaceDestination,
        before beforeBundleID: String? = nil
    ) {
        guard let bundleID, !bundleID.isEmpty else { return }

        switch destination {
        case .favorites:
            var nextFav = favorites
            if !nextFav.contains(bundleID) {
                nextFav.append(bundleID)
            }
            // Always reassign so popover UI (star) refreshes even when already favorited.
            favorites = nextFav
        case .group(let groupID):
            favorites = favorites.filter { $0 != bundleID }
            var nextGroups = groups.map { g in
                var copy = g
                copy.members = copy.members.filter { $0 != bundleID }
                return copy
            }
            if let idx = nextGroups.firstIndex(where: { $0.id == groupID }) {
                if !nextGroups[idx].members.contains(bundleID) {
                    nextGroups[idx].members.append(bundleID)
                }
            }
            groups = nextGroups
        case .other:
            favorites = favorites.filter { $0 != bundleID }
            groups = groups.map { g in
                var copy = g
                copy.members = copy.members.filter { $0 != bundleID }
                return copy
            }
        }

        ensureInOrder(bundleID)

        let peers: [String] = {
            switch destination {
            case .favorites:
                var list = order.filter { favorites.contains($0) }
                if !list.contains(bundleID) { list.append(bundleID) }
                return list
            case .group(let groupID):
                let members = Set(groups.first(where: { $0.id == groupID })?.members ?? [])
                var list = order.filter { members.contains($0) }
                if !list.contains(bundleID) { list.append(bundleID) }
                return list
            case .other:
                let grouped = Set(groups.flatMap(\.members))
                var list = order.filter { !favorites.contains($0) && !grouped.contains($0) }
                if !list.contains(bundleID) { list.append(bundleID) }
                return list
            }
        }()

        var ordered = peers.filter { $0 != bundleID }
        if let beforeBundleID, let idx = ordered.firstIndex(of: beforeBundleID) {
            ordered.insert(bundleID, at: idx)
        } else {
            ordered.append(bundleID)
        }
        applySectionOrder(ordered)
    }

    public enum PlaceDestination: Equatable, Sendable {
        case favorites
        case group(String)
        case other
    }

    // MARK: - Groups

    @discardableResult
    public func createGroup(name: String, initialMember: String?) -> Group {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Group" : trimmed
        var group = Group(name: finalName)
        if let initialMember, !initialMember.isEmpty {
            groups = groups.map { g in
                var copy = g
                copy.members = copy.members.filter { $0 != initialMember }
                return copy
            }
            group.members = [initialMember]
            ensureInOrder(initialMember)
        }
        groups = groups + [group]
        schedulePersist()
        return group
    }

    public func renameGroup(id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        var next = groups
        next[idx].name = trimmed
        groups = next
        schedulePersist()
    }

    public func deleteGroup(id: String) {
        let next = groups.filter { $0.id != id }
        guard next.count != groups.count else { return }
        groups = next
        schedulePersist()
    }

    public func add(bundleID: String?, toGroupID groupID: String) {
        guard let bundleID, !bundleID.isEmpty else { return }
        var next = groups.map { g in
            var copy = g
            copy.members = copy.members.filter { $0 != bundleID }
            return copy
        }
        guard let idx = next.firstIndex(where: { $0.id == groupID }) else { return }
        if !next[idx].members.contains(bundleID) {
            next[idx].members.append(bundleID)
        }
        groups = next
        ensureInOrder(bundleID)
        schedulePersist()
    }

    public func removeFromGroup(bundleID: String?) {
        guard let bundleID, !bundleID.isEmpty else { return }
        let next = groups.map { g in
            var copy = g
            copy.members = copy.members.filter { $0 != bundleID }
            return copy
        }
        guard next != groups else { return }
        groups = next
        schedulePersist()
    }

    // MARK: - Internals

    private func ensureInOrder(_ bundleID: String) {
        guard !bundleID.isEmpty, !order.contains(bundleID) else { return }
        order = order + [bundleID]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoded = try JSONDecoder().decode(FilePayload.self, from: data)
            favorites = decoded.favorites.filter { !$0.isEmpty }
            order = decoded.order.filter { !$0.isEmpty }
            var loaded = decoded.groups.map { g in
                Group(
                    id: g.id.isEmpty ? UUID().uuidString : g.id,
                    name: g.name.isEmpty ? "Group" : g.name,
                    members: g.members.filter { !$0.isEmpty }
                )
            }
            var seen = Set<String>()
            for i in loaded.indices {
                var unique: [String] = []
                for m in loaded[i].members where seen.insert(m).inserted {
                    unique.append(m)
                }
                loaded[i].members = unique
            }
            groups = loaded
            log.info("loaded app list favorites=\(self.favorites.count) groups=\(self.groups.count)")
        } catch {
            log.error("load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func schedulePersist() {
        revision &+= 1
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            persistNow()
        }
    }

    private func persistNow() {
        let payload = FilePayload(favorites: favorites, order: order, groups: groups)
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
