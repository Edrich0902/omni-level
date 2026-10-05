import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PerAppEQEditorHolder: ObservableObject {
    @Published var editor: PerAppEQEditorState?
}

enum MainPane: String, CaseIterable, Identifiable {
    case equalizer = "Equalizer"
    case apps = "Apps"
    case monitor = "Monitor"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .equalizer: return "slider.vertical.3"
        case .apps: return "square.stack.3d.up.fill"
        case .monitor: return "waveform"
        }
    }
}

private let appListMoveAnimation: Animation = .spring(response: 0.28, dampingFraction: 0.92)

/// Per-card heights for accurate 50% insert threshold (no layout guessing).
private struct AppCardHeightsKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Binds the Apps `ScrollView`'s hosting `NSScrollView` for edge auto-scroll while dragging.
private struct AppsScrollViewBinder: NSViewRepresentable {
    let session: AppListDragSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.isHidden = true
        DispatchQueue.main.async { session.boundScrollView = Self.enclosingScrollView(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if session.boundScrollView == nil {
            DispatchQueue.main.async { session.boundScrollView = Self.enclosingScrollView(from: nsView) }
        }
    }

    private static func enclosingScrollView(from view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let node = current {
            if let scroll = node as? NSScrollView { return scroll }
            current = node.superview
        }
        return nil
    }
}

struct ContentView: View {
    @ObservedObject var tapManager: AppAudioTapManager
    @ObservedObject var equalizerVM: EqualizerViewModel
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var nowPlaying: NowPlayingService
    @ObservedObject var appList: AppListStore
    @StateObject private var launchAtLogin = LaunchAtLoginService()
    @State private var pane: MainPane = .equalizer
    @State private var appSearch = ""
    @AppStorage("omniLevel.hideSilentApps") private var hideSilentApps = false
    @State private var silentSince: [pid_t: Date] = [:]
    /// On apps that have been quiet past the grace period; changes only on transitions.
    @State private var quietHidden: Set<pid_t> = []
    @Environment(\.liveUpdatesEnabled) private var liveUpdatesEnabled
    @StateObject private var perAppEQEditorHolder = PerAppEQEditorHolder()
    @State private var newGroupDraft = ""
    @State private var pendingNewGroupBundleID: String?
    @State private var showNewGroupAlert = false
    @State private var renameGroupDraft = ""
    @State private var renameGroupID: String?
    @State private var showRenameGroupAlert = false
    @StateObject private var dragSession = AppListDragSession()
    /// Forces Apps list redraw inside NSPopover when stores publish.
    @State private var appsPaintToken: UInt64 = 0

    private var engine: AudioEngineController { tapManager.engine }

    private var searchedApps: [AppAudioNode] {
        let q = appSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return tapManager.runningAppAudioNodes }
        return tapManager.runningAppAudioNodes.filter {
            $0.appName.localizedCaseInsensitiveContains(q)
            || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var displayedApps: [AppAudioNode] {
        let searched = searchedApps
        let searching = !appSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hideSilentApps, !searching else { return searched }
        return searched.filter { node in
            // Only hide apps we can meter (On / through OmniLevel).
            guard node.isTapped else { return true }
            // Muted On apps count as quiet.
            if node.isMuted { return false }
            return !quietHidden.contains(node.id)
        }
    }

    private var hiddenSilentCount: Int {
        guard hideSilentApps else { return 0 }
        let searching = !appSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !searching else { return 0 }
        return max(0, searchedApps.count - displayedApps.count)
    }

    private var hideSilentHint: String {
        if !hideSilentApps { return "" }
        if !appSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Search shows all matches (hide quiet is paused)"
        }
        if hiddenSilentCount > 0 {
            return "\(hiddenSilentCount) quiet On app\(hiddenSilentCount == 1 ? "" : "s") hidden"
        }
        let onCount = tapManager.runningAppAudioNodes.filter(\.isTapped).count
        if onCount == 0 {
            return "No apps are On yet — turn an app On to meter & hide quiet ones"
        }
        return "Hiding quiet On apps — pause Spotify/Arc to see them leave the list"
    }

    private var isSearching: Bool {
        !appSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sortedNodes(_ nodes: [AppAudioNode], sectionID: String? = nil) -> [AppAudioNode] {
        // Always use persisted order — never live-reorder during drag (that caused jumps).
        _ = sectionID
        return nodes.sorted {
            appList.compareForDisplay(
                $0.bundleIdentifier, nameA: $0.appName,
                $1.bundleIdentifier, nameB: $1.appName
            )
        }
    }

    /// Sectioned Apps list (Favorites → groups → Other). Flat when searching.
    private var appListSections: [AppsListSection] {
        let apps = displayedApps
        if isSearching {
            return [AppsListSection(id: "flat", title: nil, kind: .flat, nodes: sortedNodes(apps))]
        }

        let showDropZones = dragSession.draggingBundleID != nil
        var claimed = Set<pid_t>()
        var sections: [AppsListSection] = []

        let favoriteNodes = sortedNodes(
            apps.filter { appList.isFavorite(bundleID: $0.bundleIdentifier) },
            sectionID: "favorites"
        )
        if !favoriteNodes.isEmpty || showDropZones {
            claimed.formUnion(favoriteNodes.map(\.id))
            sections.append(AppsListSection(id: "favorites", title: "Favorites", kind: .favorites, nodes: favoriteNodes))
        }

        for group in appList.groups {
            let memberSet = Set(group.members)
            let sectionID = "group-\(group.id)"
            let nodes = sortedNodes(
                apps.filter { node in
                    guard !claimed.contains(node.id),
                          let bid = node.bundleIdentifier, !bid.isEmpty else { return false }
                    return memberSet.contains(bid)
                },
                sectionID: sectionID
            )
            if nodes.isEmpty && !showDropZones { continue }
            claimed.formUnion(nodes.map(\.id))
            sections.append(
                AppsListSection(id: sectionID, title: group.name, kind: .group(group), nodes: nodes)
            )
        }

        let other = sortedNodes(
            apps.filter { !claimed.contains($0.id) },
            sectionID: "other"
        )
        if !other.isEmpty || (showDropZones && !sections.isEmpty) {
            let showHeader = !sections.isEmpty
            sections.append(
                AppsListSection(
                    id: "other",
                    title: showHeader ? "Other" : nil,
                    kind: .other,
                    nodes: other
                )
            )
        }
        return sections
    }

    private func peerBundleIDs(in section: AppsListSection) -> [String] {
        section.nodes.compactMap { node in
            guard let bid = node.bundleIdentifier, !bid.isEmpty else { return nil }
            return bid
        }
    }

    private func placeDestination(for section: AppsListSection) -> AppListStore.PlaceDestination? {
        switch section.kind {
        case .favorites: return .favorites
        case .group(let group): return .group(group.id)
        case .other: return .other
        case .flat: return nil
        }
    }

    private static let dragType = UTType.utf8PlainText
    /// Fallback until GeometryReader measures a live card.
    fileprivate static let defaultCardDropHeight: CGFloat = 188

    private func makeDragProvider(bundleID: String) -> NSItemProvider {
        NSItemProvider(object: bundleID as NSString)
    }

    private func insertAfterBeforeID(for bid: String?, in section: AppsListSection) -> String? {
        let peers = peerBundleIDs(in: section)
        guard let bid, let idx = peers.firstIndex(of: bid) else { return nil }
        let next = idx + 1
        return next < peers.count ? peers[next] : nil
    }

    var body: some View {
        ZStack {
            GlassBackground()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                deviceStrip
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

                NowPlayingSection(service: nowPlaying)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

                if let error = tapManager.lastError {
                    errorBanner(error)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                paneSwitcher
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

                Group {
                    switch pane {
                    case .equalizer:
                        ScrollView {
                            EqualizerView(
                                viewModel: equalizerVM,
                                presetStore: presetStore,
                                engine: engine,
                                overrideAppCount: tapManager.eqOverrideAppCount
                            )
                                .padding(.horizontal, 16)
                                .padding(.bottom, 16)
                        }
                    case .apps:
                        appsPane
                    case .monitor:
                        VisualizerView(
                            engine: engine,
                            tapManager: tapManager,
                            isActive: pane == .monitor
                        )
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .animation(.spring(response: 0.35, dampingFraction: 0.86), value: pane)
            }
        }
        .frame(width: 480, height: 820)
        .preferredColorScheme(.dark)
        .onAppear {
            engine.refreshDevices()
            tapManager.refreshActiveAudioProcesses()
            dragSession.attach(appList: appList)
            if tapManager.isOmniLevelBypassed, tapManager.lastError != nil {
                tapManager.clearError()
            }
            refreshSilentTracking()
        }
        .onChange(of: tapManager.runningAppAudioNodes) { _, _ in
            refreshSilentTracking()
        }
    }

    private func refreshSilentTracking() {
        let now = Date()
        var next = silentSince
        let alive = Set(tapManager.runningAppAudioNodes.map(\.id))
        for node in tapManager.runningAppAudioNodes {
            let level = tapManager.liveLeveldB(for: node.id)
            if !node.isTapped || node.isMuted || level >= -42 {
                next.removeValue(forKey: node.id)
            } else if next[node.id] == nil {
                next[node.id] = now
            }
        }
        next = next.filter { alive.contains($0.key) }
        if next != silentSince {
            silentSince = next
        }
        let hidden = Set(next.filter { now.timeIntervalSince($0.value) >= 0.8 }.keys)
        if hidden != quietHidden {
            quietHidden = hidden
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        // Best-effort deep links into System Settings → Privacy & Security.
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func openPerAppEQ(for node: AppAudioNode) {
        // Toggle closed if re-tapping the same app.
        if perAppEQEditorHolder.editor?.pid == node.id {
            closePerAppEQ()
            return
        }

        let entry = tapManager.eqOverrideEntry(for: node.id)
        let seedGains = entry?.gainsdB ?? equalizerVM.bands.map(\.gaindB)
        let seedQ = entry?.qFactors ?? equalizerVM.bands.map(\.qFactor)
        let editor = PerAppEQEditorState(
            pid: node.id,
            appName: node.appName,
            seedGains: seedGains,
            seedQ: seedQ,
            seedName: entry?.name ?? equalizerVM.selectedPresetName,
            presetStore: presetStore,
            sampleRate: engine.sampleRate,
            onLiveChange: { [tapManager] gains, qs in
                tapManager.setEQOverride(pid: node.id, gains: gains, qFactors: qs, name: "Custom")
            }
        )
        tapManager.setEQOverride(pid: node.id, gains: seedGains, qFactors: seedQ, name: entry?.name)
        engine.setSpectrumFocusPID(node.id)
        withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
            perAppEQEditorHolder.editor = editor
            pane = .apps
        }
    }

    private func closePerAppEQ() {
        engine.setSpectrumFocusPID(nil)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            perAppEQEditorHolder.editor = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("OmniLevel")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, OmniTheme.accent.opacity(0.9)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    statusPill
                }
                Text(statusSubtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(OmniTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Menu {
                Toggle("Bypass OmniLevel", isOn: Binding(
                    get: { tapManager.isOmniLevelBypassed },
                    set: { tapManager.setOmniLevelBypassed($0) }
                ))

                Divider()

                Toggle("Launch at Login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))

                if let err = launchAtLogin.lastError {
                    Text(err)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Section("Privacy") {
                    Button("Audio Capture Settings") {
                        openPrivacyPane("Privacy_AudioCapture")
                    }
                    Button("Microphone Settings") {
                        openPrivacyPane("Privacy_Microphone")
                    }
                    Button("Automation Settings") {
                        openPrivacyPane("Privacy_Automation")
                    }
                }

                Divider()

                Button("Quit OmniLevel", role: .destructive) {
                    tapManager.shutdown()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 22, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(OmniTheme.textPrimary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("Settings")
        }
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .shadow(color: statusColor.opacity(0.8), radius: 4)
            Text(statusLabel)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(statusColor.opacity(0.14), in: Capsule())
        .overlay { Capsule().strokeBorder(statusColor.opacity(0.28), lineWidth: 1) }
    }

    private var statusLabel: String {
        if tapManager.isOmniLevelBypassed { return "Bypass" }
        switch engine.state {
        case .running: return "Active"
        case .stopped: return "Starting…"
        case .error: return "Error"
        }
    }

    private var statusColor: Color {
        if tapManager.isOmniLevelBypassed { return OmniTheme.amber }
        switch engine.state {
        case .running: return OmniTheme.mint
        case .stopped: return OmniTheme.amber
        case .error: return OmniTheme.coral
        }
    }

    private var statusSubtitle: String {
        if case .error(let m) = engine.state, !tapManager.isOmniLevelBypassed { return m }
        if !tapManager.engineStatusMessage.isEmpty {
            return tapManager.engineStatusMessage
        }
        return "→ \(engine.outputDeviceName)"
    }

    // MARK: - Devices

    private var deviceStrip: some View {
        HStack(spacing: 10) {
            devicePicker(
                label: "Input",
                icon: "mic.fill",
                selection: Binding(
                    get: { engine.selectedInputDeviceID },
                    set: { engine.selectInputDevice($0) }
                ),
                devices: engine.devices.inputDevices
            )

            devicePicker(
                label: "Output",
                icon: "hifispeaker.fill",
                selection: Binding(
                    get: { engine.selectedOutputDeviceID },
                    set: { engine.selectOutputDevice($0) }
                ),
                devices: engine.devices.outputDevices
            )
        }
        .padding(12)
        .glassCard(cornerRadius: 16, elevated: false)
        .opacity(tapManager.isOmniLevelBypassed ? 0.55 : 1)
    }

    private func devicePicker(
        label: String,
        icon: String,
        selection: Binding<UInt32>,
        devices: [AudioDeviceInfo]
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(OmniTheme.accent)
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(OmniTheme.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            Picker(label, selection: selection) {
                ForEach(devices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(OmniTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Tabs

    private var paneSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(MainPane.allCases) { p in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        pane = p
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: p.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(p.rawValue)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(pane == p ? Color.black.opacity(0.88) : OmniTheme.textPrimary.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                pane == p
                                    ? AnyShapeStyle(
                                        LinearGradient(
                                            colors: [OmniTheme.accent, OmniTheme.mint.opacity(0.85)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    : AnyShapeStyle(Color.clear)
                            )
                            .shadow(color: pane == p ? OmniTheme.accent.opacity(0.35) : .clear, radius: 10, y: 3)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OmniTheme.fill)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(OmniTheme.stroke, lineWidth: 1)
                }
        }
    }

    // MARK: - Apps pane

    private var appsPane: some View {
        // Touch paint tokens so NSPopover hosting refreshes when stores publish.
        let _ = appsPaintToken
        let _ = appList.revision
        let _ = tapManager.runningAppAudioNodes.map { "\($0.id):\($0.isMuted):\($0.isTapped):\($0.isSolo)" }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SectionLabel(
                    title: "Applications",
                    trailing: "\(displayedApps.count)"
                )
                Spacer(minLength: 0)
                Toggle(isOn: $hideSilentApps) {
                    Text("Hide quiet")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(OmniTheme.textSecondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Hide On apps that aren’t currently playing audio (and muted On apps). Off apps stay visible.")
            }
            .padding(.horizontal, 16)

            if hideSilentApps, !hideSilentHint.isEmpty {
                Text(hideSilentHint)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(OmniTheme.textSecondary)
                    .padding(.horizontal, 16)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OmniTheme.textSecondary)
                TextField("Search apps", text: $appSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(OmniTheme.textPrimary)
                if !appSearch.isEmpty {
                    Button {
                        appSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(OmniTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassCard(cornerRadius: 12, elevated: false)
            .padding(.horizontal, 16)

            if tapManager.runningAppAudioNodes.isEmpty {
                emptyState(message: "No apps detected yet")
            } else if displayedApps.isEmpty {
                emptyState(
                    message: appSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "All routed apps are silent"
                        : "No apps match “\(appSearch)”"
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            AppsScrollViewBinder(session: dragSession)
                                .frame(width: 0, height: 0)

                            ForEach(appListSections) { section in
                                if let title = section.title {
                                    appsSectionHeader(section)
                                        .padding(.top, section.id == appListSections.first?.id ? 0 : 6)
                                }

                                if section.nodes.isEmpty, dragSession.draggingBundleID != nil, section.title != nil {
                                    Text("Drop here")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(OmniTheme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 14)
                                        .padding(.horizontal, 12)
                                        .background {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .strokeBorder(
                                                    dragSession.isDropTarget(highlightID: section.id)
                                                        ? OmniTheme.accent.opacity(0.8)
                                                        : OmniTheme.strokeSoft,
                                                    style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
                                                )
                                        }
                                        .onDrop(
                                            of: [Self.dragType],
                                            delegate: AppListDropDelegate(
                                                destination: placeDestination(for: section),
                                                beforeBundleID: nil,
                                                appendToEnd: true,
                                                appList: appList,
                                                dragSession: dragSession,
                                                sectionID: section.id,
                                                highlightID: section.id
                                            )
                                        )
                                }

                                ForEach(section.nodes) { node in
                                    let bid = node.bundleIdentifier
                                    let isDragSource = dragSession.draggingBundleID != nil
                                        && bid == dragSession.draggingBundleID
                                    let showInsertBefore = dragSession.showsInsertion(
                                        before: bid,
                                        inSection: section.id
                                    )

                                    appCard(for: node, in: section)
                                        .id(node.id)
                                        // Keep layout height stable — never swap the card out mid-drag.
                                        .opacity(isDragSource ? 0 : 1)
                                        .overlay {
                                            if isDragSource {
                                                dragSourcePlaceholder
                                            }
                                        }
                                        .overlay(alignment: .top) {
                                            // Overlay marker: no layout shift / no card jumps.
                                            if showInsertBefore {
                                                insertionIndicator
                                                    .offset(y: -5)
                                            }
                                        }
                                        .background {
                                            GeometryReader { geo in
                                                Color.clear.preference(
                                                    key: AppCardHeightsKey.self,
                                                    value: bid.map { [$0: geo.size.height] } ?? [:]
                                                )
                                            }
                                        }
                                        .animation(nil, value: isDragSource)

                                    if let editor = perAppEQEditorHolder.editor, editor.pid == node.id {
                                        PerAppEQEditorPanel(
                                            editor: editor,
                                            presetStore: presetStore,
                                            engine: engine,
                                            onDone: { closePerAppEQ() },
                                            onUseGlobal: {
                                                tapManager.clearEQOverride(pid: editor.pid)
                                                closePerAppEQ()
                                            }
                                        )
                                        .id("eq-\(node.id)")
                                        .transition(
                                            .asymmetric(
                                                insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .move(edge: .top).combined(with: .opacity)
                                            )
                                        )
                                    }
                                }

                                if dragSession.draggingBundleID != nil, placeDestination(for: section) != nil {
                                    sectionEndDropZone(section)
                                        .overlay(alignment: .top) {
                                            if dragSession.showsInsertion(before: nil, inSection: section.id) {
                                                insertionIndicator
                                                    .offset(y: -5)
                                            }
                                        }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, dragSession.draggingBundleID == nil ? 16 : 96)
                        // Only animate committed reorders — never animate the insertion marker.
                        .animation(appListMoveAnimation, value: appList.revision)
                        .animation(
                            .spring(response: 0.36, dampingFraction: 0.88),
                            value: perAppEQEditorHolder.editor?.pid
                        )
                        .onPreferenceChange(AppCardHeightsKey.self) { heights in
                            dragSession.cardHeights.merge(heights, uniquingKeysWith: { _, new in new })
                            if let maxH = heights.values.max(), maxH > 80 {
                                dragSession.cardHeight = maxH
                            }
                        }
                    }
                    .onChange(of: perAppEQEditorHolder.editor?.pid) { _, pid in
                        guard let pid else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
                                proxy.scrollTo("eq-\(pid)", anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Drives the level feed (only the meter leaf views observe it) and drag polling.
        // Runs only while the Apps pane is on screen in an open popover.
        .background {
            TimelineView(
                .animation(
                    minimumInterval: dragSession.draggingBundleID == nil ? 1.0 / 30.0 : 1.0 / 60.0,
                    paused: !liveUpdatesEnabled
                )
            ) { timeline in
                Color.clear
                    .onChange(of: timeline.date) { _, _ in
                        tapManager.pumpLiveLevels()
                        refreshSilentTracking()
                        dragSession.endIfMouseReleased()
                        if dragSession.draggingBundleID != nil {
                            dragSession.autoScrollIfNeeded()
                        }
                    }
                    .onAppear {
                        tapManager.pumpLiveLevels()
                    }
            }
        }
        .onReceive(appList.objectWillChange) { _ in
            DispatchQueue.main.async { appsPaintToken &+= 1 }
        }
        .onChange(of: appList.revision) { _, _ in
            appsPaintToken &+= 1
        }
        .alert("New Group", isPresented: $showNewGroupAlert) {
            TextField("Name", text: $newGroupDraft)
            Button("Cancel", role: .cancel) {
                pendingNewGroupBundleID = nil
                newGroupDraft = ""
            }
            Button("Create") {
                let member = pendingNewGroupBundleID
                appList.createGroup(name: newGroupDraft, initialMember: member)
                pendingNewGroupBundleID = nil
                newGroupDraft = ""
            }
        } message: {
            Text("Apps in a group appear together in the Apps list.")
        }
        .alert("Rename Group", isPresented: $showRenameGroupAlert) {
            TextField("Name", text: $renameGroupDraft)
            Button("Cancel", role: .cancel) {
                renameGroupID = nil
                renameGroupDraft = ""
            }
            Button("Save") {
                if let id = renameGroupID {
                    appList.renameGroup(id: id, name: renameGroupDraft)
                }
                renameGroupID = nil
                renameGroupDraft = ""
            }
        }
    }

    private var insertionIndicator: some View {
        Capsule()
            .fill(OmniTheme.accent)
            .frame(height: 3)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .shadow(color: OmniTheme.accent.opacity(0.45), radius: 4, y: 0)
    }

    private var dragSourcePlaceholder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(OmniTheme.strokeSoft, style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OmniTheme.fill.opacity(0.35))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func sectionEndDropZone(_ section: AppsListSection) -> some View {
        let endID = section.id + "#end"
        let isActive = dragSession.isDropTarget(highlightID: endID)

        VStack(spacing: 6) {
            Text(isActive ? "Release to place at end" : "Drop at end")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(isActive ? OmniTheme.accent : OmniTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? OmniTheme.accent.opacity(0.12) : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isActive ? OmniTheme.accent.opacity(0.65) : OmniTheme.strokeSoft.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1, dash: isActive ? [] : [5, 4])
                        )
                }
        }
        .onDrop(
            of: [Self.dragType],
            delegate: AppListDropDelegate(
                destination: placeDestination(for: section),
                beforeBundleID: nil,
                appendToEnd: true,
                appList: appList,
                dragSession: dragSession,
                sectionID: section.id,
                highlightID: endID
            )
        )
    }

    @ViewBuilder
    private func appsSectionHeader(_ section: AppsListSection) -> some View {
        let isDropTarget = dragSession.isDropTarget(highlightID: section.id) && dragSession.draggingBundleID != nil

        HStack(spacing: 8) {
            Text(section.title ?? "")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(OmniTheme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text("\(section.nodes.count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(OmniTheme.textSecondary.opacity(0.7))
            Spacer(minLength: 0)

            if case .favorites = section.kind {
                Menu {
                    Button("Mute All") {
                        for node in section.nodes { tapManager.setMuted(pid: node.id, muted: true) }
                    }
                    Button("Unmute All") {
                        for node in section.nodes { tapManager.setMuted(pid: node.id, muted: false) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OmniTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help("Favorites actions")
            }

            if case .group(let group) = section.kind {
                Menu {
                    Button("Mute All") {
                        for node in section.nodes { tapManager.setMuted(pid: node.id, muted: true) }
                    }
                    Button("Unmute All") {
                        for node in section.nodes { tapManager.setMuted(pid: node.id, muted: false) }
                    }
                    Divider()
                    Button("Bypass All") {
                        for node in section.nodes {
                            tapManager.setRoute(pid: node.id, throughOmniLevel: false)
                        }
                    }
                    Button("Route All") {
                        for node in section.nodes {
                            tapManager.setRoute(pid: node.id, throughOmniLevel: true)
                        }
                    }
                    Divider()
                    Button("Rename…") {
                        renameGroupID = group.id
                        renameGroupDraft = group.name
                        showRenameGroupAlert = true
                    }
                    Button("Delete Group", role: .destructive) {
                        appList.deleteGroup(id: group.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OmniTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help("Group actions")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDropTarget ? OmniTheme.accent.opacity(0.18) : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isDropTarget ? OmniTheme.accent.opacity(0.7) : Color.clear,
                            lineWidth: 1.5
                        )
                }
        }
        .onDrop(
            of: [Self.dragType],
            delegate: AppListDropDelegate(
                destination: placeDestination(for: section),
                beforeBundleID: nil,
                appList: appList,
                dragSession: dragSession,
                sectionID: section.id
            )
        )
    }

    private func appCard(for node: AppAudioNode, in section: AppsListSection) -> some View {
        let bid = node.bundleIdentifier
        let peers = peerBundleIDs(in: section)
        let peerIndex = bid.flatMap { peers.firstIndex(of: $0) }
        let canOrganize = !(bid ?? "").isEmpty
        let favorited = appList.isFavorite(bundleID: bid)
        let membership = appList.group(containing: bid)
        let destination = placeDestination(for: section)

        return AppVolumeCard(
            node: node,
            levelFeed: tapManager.liveLevels,
            outputDevices: engine.devices.outputDevices,
            isFavorite: favorited,
            canOrganize: canOrganize,
            canMoveUp: canOrganize && (peerIndex ?? 0) > 0,
            canMoveDown: canOrganize && peerIndex.map { $0 + 1 < peers.count } == true,
            groupName: membership?.name,
            availableGroups: appList.groups.map { (id: $0.id, name: $0.name) },
            onVolume: { tapManager.setVolume(pid: node.id, volume: $0) },
            onPan: { tapManager.setPan(pid: node.id, pan: $0) },
            onMute: { tapManager.toggleMute(pid: node.id) },
            onSolo: { tapManager.toggleSolo(pid: node.id) },
            onToggleTap: { tapManager.toggleTap(for: node.id) },
            onEditEQ: { openPerAppEQ(for: node) },
            onUseGlobalEQ: {
                tapManager.clearEQOverride(pid: node.id)
                if perAppEQEditorHolder.editor?.pid == node.id {
                    closePerAppEQ()
                }
            },
            onSelectOutputUID: { tapManager.setOutputDeviceUID($0, for: node.id) },
            onToggleFavorite: { appList.toggleFavorite(bundleID: bid) },
            onMoveUp: {
                appList.move(bundleID: bid, amongPeers: peers, direction: .up)
            },
            onMoveDown: {
                appList.move(bundleID: bid, amongPeers: peers, direction: .down)
            },
            onAddToGroup: { groupID in
                appList.add(bundleID: bid, toGroupID: groupID)
            },
            onCreateGroup: {
                pendingNewGroupBundleID = bid
                newGroupDraft = ""
                showNewGroupAlert = true
            },
            onRemoveFromGroup: {
                appList.removeFromGroup(bundleID: bid)
            },
            onDragStart: {
                dragSession.begin(bid, from: destination, sectionID: section.id, peers: peers)
            },
            onDragProvider: {
                guard let bid else { return NSItemProvider() }
                dragSession.begin(bid, from: destination, sectionID: section.id, peers: peers)
                return makeDragProvider(bundleID: bid)
            }
        )
        .onDrop(
            of: [Self.dragType],
            delegate: AppListDropDelegate(
                destination: destination,
                beforeBundleID: bid,
                insertAfterBeforeBundleID: insertAfterBeforeID(for: bid, in: section),
                appList: appList,
                dragSession: dragSession,
                sectionID: section.id,
                targetHeight: bid.flatMap { dragSession.cardHeights[$0] }
            )
        )
    }

    private func emptyState(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "app.dashed")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(OmniTheme.textSecondary)
            Text(message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(OmniTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(cornerRadius: 16, elevated: false)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(OmniTheme.coral)
            Text(message)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(OmniTheme.textPrimary)
                .lineLimit(2)
            Spacer()
            Button {
                tapManager.clearError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(OmniTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OmniTheme.coral.opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(OmniTheme.coral.opacity(0.35), lineWidth: 1)
                }
        }
    }
}

// MARK: - Apps list sections

private struct AppsListSection: Identifiable {
    enum Kind {
        case flat
        case favorites
        case group(AppListStore.Group)
        case other
    }

    let id: String
    let title: String?
    let kind: Kind
    let nodes: [AppAudioNode]
}

/// Tracks an in-progress Apps-list drag.
/// Cards stay put while dragging; only an overlay insertion marker moves (no live reshuffle = no jumps).
@MainActor
private final class AppListDragSession: ObservableObject {
    @Published var draggingBundleID: String?
    @Published var highlightedSectionID: String?
    @Published var activeDropSectionID: String?
    @Published var insertionBeforeBundleID: String?
    var originDestination: AppListStore.PlaceDestination?
    var originSectionID: String?
    var originPeers: [String] = []
    var cardHeight: CGFloat = ContentView.defaultCardDropHeight
    var cardHeights: [String: CGFloat] = [:]
    var pendingDestination: AppListStore.PlaceDestination?
    var pendingBeforeBundleID: String?
    weak var boundScrollView: NSScrollView?
    private var lastHoverKey: String?
    private var didCommit = false
    private var mouseUpMonitor: Any?
    private weak var appList: AppListStore?

    func attach(appList: AppListStore) {
        self.appList = appList
    }

    func isDropTarget(highlightID: String) -> Bool {
        draggingBundleID != nil && highlightedSectionID == highlightID
    }

    func showsInsertion(before bundleID: String?, inSection sectionID: String) -> Bool {
        guard draggingBundleID != nil, activeDropSectionID == sectionID else { return false }
        return insertionBeforeBundleID == bundleID
    }

    func begin(
        _ bundleID: String?,
        from origin: AppListStore.PlaceDestination?,
        sectionID: String,
        peers: [String]
    ) {
        guard let bundleID, !bundleID.isEmpty else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            draggingBundleID = bundleID
        }
        if originDestination == nil {
            originDestination = origin
            originSectionID = sectionID
            originPeers = peers
            activeDropSectionID = sectionID
            pendingDestination = origin
            pendingBeforeBundleID = nil
            insertionBeforeBundleID = nil
            lastHoverKey = nil
            didCommit = false
        }
        if mouseUpMonitor == nil {
            mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
                DispatchQueue.main.async {
                    self?.commitOnMouseUpIfNeeded()
                }
                return event
            }
        }
    }

    /// Update insertion marker only — never reshuffles list rows during drag.
    /// No animation: animating marker moves is what made cards feel haywire.
    func setInsertionTarget(
        before beforeBundleID: String?,
        sectionID: String,
        destination: AppListStore.PlaceDestination,
        highlightID: String
    ) {
        let key = "\(sectionID)|\(beforeBundleID ?? "__end__")"
        guard lastHoverKey != key else {
            if highlightedSectionID != highlightID {
                highlightedSectionID = highlightID
            }
            return
        }
        lastHoverKey = key
        insertionBeforeBundleID = beforeBundleID
        activeDropSectionID = sectionID
        highlightedSectionID = highlightID
        pendingDestination = destination
        pendingBeforeBundleID = beforeBundleID
    }

    func commit(
        bundleID: String,
        destination: AppListStore.PlaceDestination,
        before: String?,
        sameSection: Bool,
        appList: AppListStore
    ) {
        guard !didCommit else {
            end(animated: false)
            return
        }
        didCommit = true

        withAnimation(appListMoveAnimation) {
            if sameSection {
                var next = originPeers.filter { $0 != bundleID }
                if next.isEmpty && originPeers.isEmpty {
                    next = [bundleID]
                } else if let before, let idx = next.firstIndex(of: before) {
                    next.insert(bundleID, at: idx)
                } else {
                    next.append(bundleID)
                }
                appList.applySectionOrder(next)
            } else {
                appList.place(bundleID: bundleID, destination: destination, before: before)
            }
        }
        end(animated: false)
    }

    func commitOnMouseUpIfNeeded() {
        guard draggingBundleID != nil, !didCommit else {
            end(animated: false)
            return
        }
        guard let bundleID = draggingBundleID, let appList else {
            end(animated: false)
            return
        }
        let origin = originDestination
        let pending = pendingDestination ?? origin
        let before = pendingBeforeBundleID
        let sameSection = pending == origin

        guard let pending else {
            end(animated: false)
            return
        }
        commit(
            bundleID: bundleID,
            destination: pending,
            before: before,
            sameSection: sameSection,
            appList: appList
        )
    }

    func endIfMouseReleased() {
        guard draggingBundleID != nil else { return }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            commitOnMouseUpIfNeeded()
        }
    }

    /// Scroll when the pointer is near the top/bottom of the apps scroll view (accelerates into the edge).
    func autoScrollIfNeeded() {
        guard draggingBundleID != nil else { return }
        let scroll = boundScrollView
            ?? (NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible)).flatMap { findScrollView(in: $0.contentView) }
        guard let scroll, let window = scroll.window else { return }
        boundScrollView = scroll

        // Window coords: origin bottom-left. Compare against the scroll view's frame in the same space.
        let mouse = window.mouseLocationOutsideOfEventStream
        let frame = scroll.convert(scroll.bounds, to: nil)
        let edge: CGFloat = 52
        let distFromTop = frame.maxY - mouse.y
        let distFromBottom = mouse.y - frame.minY

        // Allow auto-scroll slightly outside the scroll view while dragging past the popover edge.
        let expanded = frame.insetBy(dx: -8, dy: -24)
        guard expanded.contains(mouse) || distFromTop < edge || distFromBottom < edge else { return }

        var delta: CGFloat = 0
        if distFromTop < edge {
            let t = max(0, min(1, 1 - distFromTop / edge))
            // Near top → reveal content above.
            delta = -(3 + t * t * 36)
        } else if distFromBottom < edge {
            let t = max(0, min(1, 1 - distFromBottom / edge))
            // Near bottom → reveal content below.
            delta = 3 + t * t * 36
        } else {
            return
        }

        let clip = scroll.contentView
        var origin = clip.bounds.origin
        let visibleH = clip.documentVisibleRect.height
        let docH = scroll.documentView?.frame.height ?? 0
        let maxY = max(0, docH - visibleH)

        if clip.isFlipped {
            origin.y = max(0, min(maxY, origin.y + delta))
        } else {
            // Non-flipped: increasing y moves toward top of document.
            origin.y = max(0, min(maxY, origin.y - delta))
        }

        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func findScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let scroll = findScrollView(in: sub) { return scroll }
        }
        return nil
    }

    func end(animated: Bool = true) {
        let clear = {
            self.draggingBundleID = nil
            self.highlightedSectionID = nil
            self.activeDropSectionID = nil
            self.insertionBeforeBundleID = nil
        }
        if animated {
            withAnimation(appListMoveAnimation, clear)
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction, clear)
        }
        originDestination = nil
        originSectionID = nil
        originPeers = []
        pendingDestination = nil
        pendingBeforeBundleID = nil
        lastHoverKey = nil
        didCommit = false
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
            self.mouseUpMonitor = nil
        }
        objectWillChange.send()
    }
}

/// Drop onto a section header or card. List rows do not reshuffle until drop commits.
private struct AppListDropDelegate: DropDelegate {
    let destination: AppListStore.PlaceDestination?
    let beforeBundleID: String?
    var insertAfterBeforeBundleID: String? = nil
    var appendToEnd: Bool = false
    let appList: AppListStore
    let dragSession: AppListDragSession
    let sectionID: String
    var highlightID: String? = nil
    var targetHeight: CGFloat? = nil

    private var resolvedHighlightID: String { highlightID ?? sectionID }

    func dropEntered(info: DropInfo) {
        updateInsertion(info: info)
    }

    func dropExited(info: DropInfo) {
        if dragSession.highlightedSectionID == resolvedHighlightID {
            dragSession.highlightedSectionID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateInsertion(info: info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let destination,
              let bundleID = dragSession.draggingBundleID,
              !bundleID.isEmpty else {
            dragSession.end(animated: false)
            return false
        }

        let before = appendToEnd ? nil : insertBefore(for: info)
        let sameSection = destination == dragSession.originDestination
        dragSession.commit(
            bundleID: bundleID,
            destination: destination,
            before: before,
            sameSection: sameSection,
            appList: appList
        )
        return true
    }

    private func updateInsertion(info: DropInfo) {
        guard let destination,
              let dragging = dragSession.draggingBundleID,
              !dragging.isEmpty else { return }

        if appendToEnd {
            dragSession.setInsertionTarget(
                before: nil,
                sectionID: sectionID,
                destination: destination,
                highlightID: resolvedHighlightID
            )
            return
        }

        if beforeBundleID == dragging {
            dragSession.highlightedSectionID = resolvedHighlightID
            return
        }

        dragSession.setInsertionTarget(
            before: insertBefore(for: info),
            sectionID: sectionID,
            destination: destination,
            highlightID: resolvedHighlightID
        )
    }

    /// Top half → insert before this card; bottom half → insert after it (50% threshold).
    private func insertBefore(for info: DropInfo) -> String? {
        if appendToEnd { return nil }
        let height = max(
            targetHeight
                ?? beforeBundleID.flatMap { dragSession.cardHeights[$0] }
                ?? dragSession.cardHeight,
            40
        )
        // DropInfo.location is in the drop target's space (top-left origin).
        if info.location.y < height * 0.5 {
            return beforeBundleID
        }
        return insertAfterBeforeBundleID
    }
}
