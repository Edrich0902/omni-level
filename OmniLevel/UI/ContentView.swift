import AppKit
import SwiftUI

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

struct ContentView: View {
    @ObservedObject var tapManager: AppAudioTapManager
    @ObservedObject var equalizerVM: EqualizerViewModel
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var nowPlaying: NowPlayingService
    @StateObject private var launchAtLogin = LaunchAtLoginService()
    @State private var pane: MainPane = .equalizer
    @State private var appSearch = ""
    @AppStorage("omniLevel.hideSilentApps") private var hideSilentApps = false
    @State private var silentSince: [pid_t: Date] = [:]
    /// Local copy refreshed by TimelineView so Apps VU redraws inside the menu-bar popover.
    @State private var appsLiveLevels: [pid_t: Float] = [:]
    @StateObject private var perAppEQEditorHolder = PerAppEQEditorHolder()

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
        let now = Date()
        return searched.filter { node in
            // Only hide apps we can meter (On / through OmniLevel).
            guard node.isTapped else { return true }
            // Muted On apps count as quiet.
            if node.isMuted { return false }
            let level = appsLiveLevels[node.id] ?? tapManager.liveLeveldB(for: node.id)
            if level >= -42 { return true }
            guard let since = silentSince[node.id] else { return true }
            return now.timeIntervalSince(since) < 0.8
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
                        VisualizerView(engine: engine)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .animation(.spring(response: 0.35, dampingFraction: 0.86), value: pane)
            }
        }
        .frame(width: 480, height: 760)
        .preferredColorScheme(.dark)
        .onAppear {
            engine.refreshDevices()
            tapManager.refreshActiveAudioProcesses()
            if tapManager.isOmniLevelBypassed, tapManager.lastError != nil {
                tapManager.clearError()
            }
            refreshSilentTracking()
        }
        .onChange(of: tapManager.runningAppAudioNodes) { _, _ in
            refreshSilentTracking()
        }
        .onChange(of: tapManager.liveLevelsdB) { _, _ in
            refreshSilentTracking()
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            refreshSilentTracking()
        }
    }

    private func refreshSilentTracking() {
        let now = Date()
        var next = silentSince
        let alive = Set(tapManager.runningAppAudioNodes.map(\.id))
        for node in tapManager.runningAppAudioNodes {
            let level = appsLiveLevels[node.id] ?? tapManager.liveLeveldB(for: node.id)
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
        VStack(alignment: .leading, spacing: 10) {
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
                        LazyVStack(spacing: 8) {
                            ForEach(displayedApps) { node in
                                AppVolumeCard(
                                    node: node,
                                    leveldB: appsLiveLevels[node.id] ?? tapManager.liveLeveldB(for: node.id),
                                    outputDevices: engine.devices.outputDevices,
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
                                    onSelectOutputUID: { tapManager.setOutputDeviceUID($0, for: node.id) }
                                )
                                .id(node.id)

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
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                        .animation(
                            .spring(response: 0.36, dampingFraction: 0.88),
                            value: perAppEQEditorHolder.editor?.pid
                        )
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
        // Popover won't reliably redraw from Timer/@Published — same pattern as EQ fader meters.
        .background {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                Color.clear
                    .onChange(of: timeline.date) { _, _ in
                        appsLiveLevels = tapManager.pumpLiveLevels()
                        refreshSilentTracking()
                    }
                    .onAppear {
                        appsLiveLevels = tapManager.pumpLiveLevels()
                    }
            }
        }
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
