import AppKit
import SwiftUI

struct AppVolumeCard: View {
    let node: AppAudioNode
    /// Live loudness feed; only the level row observes it so meter ticks don't rebuild the card.
    let levelFeed: LiveLevelFeed
    let outputDevices: [AudioDeviceInfo]
    var isFavorite: Bool = false
    var canOrganize: Bool = false
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false
    var groupName: String? = nil
    var availableGroups: [(id: String, name: String)] = []
    var onVolume: (Float) -> Void
    var onPan: (Float) -> Void
    var onMute: () -> Void
    var onSolo: () -> Void
    var onToggleTap: () -> Void
    var onEditEQ: () -> Void
    var onUseGlobalEQ: () -> Void
    var onSelectOutputUID: (String?) -> Void
    var onToggleFavorite: () -> Void = {}
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var onAddToGroup: (String) -> Void = { _ in }
    var onCreateGroup: () -> Void = {}
    var onRemoveFromGroup: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragProvider: () -> NSItemProvider = { NSItemProvider() }

    private var panOffCenter: Bool { abs(node.pan) > 0.02 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Identity row
            HStack(spacing: 10) {
                ZStack {
                    if node.isTapped {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(OmniTheme.accent.opacity(0.55), lineWidth: 1.5)
                            .frame(width: 36, height: 36)
                    }
                    Image(nsImage: node.appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(node.appName)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(OmniTheme.textPrimary)
                            .lineLimit(1)
                        if node.hasEQOverride {
                            Text("EQ")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(OmniTheme.accent.opacity(0.75), in: Capsule())
                                .help("Per-app EQ override active")
                        }
                    }
                    Text(node.isTapped ? "Through OmniLevel" : "Bypassing OmniLevel")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(node.isTapped ? OmniTheme.mint : OmniTheme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if canOrganize {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OmniTheme.textSecondary.opacity(0.85))
                        .frame(width: 22, height: 28)
                        .contentShape(Rectangle())
                        .help("Drag to reorder or move to Favorites / a group")
                        .onDrag {
                            onDragStart()
                            return onDragProvider()
                        } preview: {
                            cardDragGhost
                        }

                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isFavorite ? OmniTheme.amber : OmniTheme.textSecondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                            .id(isFavorite)
                    }
                    .buttonStyle(.plain)
                    .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
                }

                HStack(spacing: 6) {
                    controlButton(
                        title: "Mute",
                        systemImage: node.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        active: node.isMuted,
                        tint: OmniTheme.coral,
                        action: onMute
                    )
                    controlButton(
                        title: "Solo",
                        systemImage: "headphones",
                        active: node.isSolo,
                        tint: OmniTheme.amber,
                        action: onSolo
                    )
                    controlButton(
                        title: node.isTapped ? "On" : "Off",
                        systemImage: "arrow.triangle.branch",
                        active: node.isTapped,
                        tint: OmniTheme.accent,
                        action: onToggleTap
                    )
                    .help(node.isTapped
                          ? "Stop routing this app through OmniLevel"
                          : "Route this app’s audio through OmniLevel EQ")
                }
            }

            // Volume
            HStack(spacing: 8) {
                Text("Volume")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(OmniTheme.textSecondary)
                    .frame(width: 52, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(node.volume) },
                        set: { onVolume(Float($0)) }
                    ),
                    in: 0...2
                )
                .tint(OmniTheme.mint)
                .controlSize(.small)
                Text("\(node.volumePercent)%")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(OmniTheme.textPrimary.opacity(0.85))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }

            // Live signal level (how loud the app is right now — not the volume knob)
            HStack(spacing: 8) {
                Text("Level")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(OmniTheme.textSecondary)
                    .frame(width: 52, alignment: .leading)
                AppLiveLevelRow(feed: levelFeed, pid: node.id, isActive: node.isTapped)
            }

            // Balance
            HStack(spacing: 8) {
                Text("Balance")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(OmniTheme.textSecondary)
                    .frame(width: 52, alignment: .leading)
                Text("L")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(OmniTheme.textSecondary)
                Slider(
                    value: Binding(
                        get: { Double(node.pan) },
                        set: { onPan(Float($0)) }
                    ),
                    in: -1...1
                )
                .tint(OmniTheme.accent)
                .controlSize(.small)
                Text("R")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(OmniTheme.textSecondary)
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                        onPan(0)
                    }
                } label: {
                    Image(systemName: "circle.dotted")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(panOffCenter ? OmniTheme.accent : OmniTheme.textSecondary.opacity(0.4))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Center balance")
                .disabled(!panOffCenter)
                .opacity(panOffCenter ? 1 : 0.5)
            }

            // EQ + Output
            HStack(spacing: 8) {
                Menu {
                    Button("Edit EQ…") { onEditEQ() }
                    if node.hasEQOverride {
                        Button("Use global EQ") { onUseGlobalEQ() }
                    }
                } label: {
                    Label(
                        node.hasEQOverride ? "Custom EQ" : "EQ",
                        systemImage: "slider.vertical.3"
                    )
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(OmniTheme.textPrimary.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(OmniTheme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                node.hasEQOverride ? OmniTheme.accent.opacity(0.7) : OmniTheme.strokeSoft,
                                lineWidth: 1
                            )
                    }
                }
                .menuStyle(.borderlessButton)

                Menu {
                    Button {
                        onSelectOutputUID(nil)
                    } label: {
                        HStack {
                            Text("System Default")
                            if node.outputDeviceUID == nil { Image(systemName: "checkmark") }
                        }
                    }
                    Divider()
                    ForEach(outputDevices) { device in
                        Button {
                            onSelectOutputUID(device.uid)
                        } label: {
                            HStack {
                                Text(device.name)
                                if node.outputDeviceUID == device.uid {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "hifispeaker.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(outputLabel)
                            .lineLimit(1)
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(node.outputFallback ? OmniTheme.amber : OmniTheme.textPrimary.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(OmniTheme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                node.outputFallback ? OmniTheme.amber.opacity(0.7) : OmniTheme.strokeSoft,
                                lineWidth: 1
                            )
                    }
                }
                .menuStyle(.borderlessButton)
                .help(node.outputFallback
                      ? "Preferred output unavailable — using System Default"
                      : "Route this app to a specific output")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 14, elevated: false)
        .opacity(node.isMuted && !node.isSolo ? 0.72 : 1)
        .contextMenu {
            if canOrganize {
                Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", action: onToggleFavorite)
                Divider()
                Button("Move Up", action: onMoveUp)
                    .disabled(!canMoveUp)
                Button("Move Down", action: onMoveDown)
                    .disabled(!canMoveDown)
                Divider()
                Menu("Add to Group") {
                    ForEach(availableGroups, id: \.id) { group in
                        Button(group.name) { onAddToGroup(group.id) }
                    }
                    if !availableGroups.isEmpty {
                        Divider()
                    }
                    Button("New Group…", action: onCreateGroup)
                }
                if groupName != nil {
                    Button("Remove from \(groupName ?? "Group")", action: onRemoveFromGroup)
                } else {
                    Button("Create Group with App…", action: onCreateGroup)
                }
            }
        }
    }

    private var outputLabel: String {
        if node.outputFallback {
            return "Fallback · Default"
        }
        if let uid = node.outputDeviceUID,
           let name = outputDevices.first(where: { $0.uid == uid })?.name {
            return name
        }
        return "System Default"
    }

    /// Full-card lift preview while dragging from the grip only.
    private var cardDragGhost: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    if node.isTapped {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(OmniTheme.accent.opacity(0.55), lineWidth: 1.5)
                            .frame(width: 36, height: 36)
                    }
                    Image(nsImage: node.appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(node.appName)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(OmniTheme.textPrimary)
                            .lineLimit(1)
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(OmniTheme.amber)
                        }
                        if node.hasEQOverride {
                            Text("EQ")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(OmniTheme.accent.opacity(0.75), in: Capsule())
                        }
                    }
                    Text(node.isTapped ? "Through OmniLevel" : "Bypassing OmniLevel")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(node.isTapped ? OmniTheme.mint : OmniTheme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    ghostChip(
                        systemImage: node.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        active: node.isMuted,
                        tint: OmniTheme.coral
                    )
                    ghostChip(
                        systemImage: "headphones",
                        active: node.isSolo,
                        tint: OmniTheme.amber
                    )
                    ghostChip(
                        systemImage: "arrow.triangle.branch",
                        active: node.isTapped,
                        tint: OmniTheme.accent
                    )
                }
            }

            HStack(spacing: 8) {
                Text("Volume")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(OmniTheme.textSecondary)
                    .frame(width: 52, alignment: .leading)
                Capsule()
                    .fill(OmniTheme.fill)
                    .frame(height: 6)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(OmniTheme.mint.opacity(0.85))
                            .frame(width: 160 * CGFloat(min(max(node.volume / 2, 0), 1)), height: 6)
                    }
                Text("\(node.volumePercent)%")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(OmniTheme.textPrimary.opacity(0.85))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Text("Level")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(OmniTheme.textSecondary)
                    .frame(width: 52, alignment: .leading)
                AppLiveLevelRow(feed: levelFeed, pid: node.id, isActive: node.isTapped)
            }
        }
        .padding(12)
        .frame(width: 420, alignment: .leading)
        .glassCard(cornerRadius: 14, elevated: true)
        .opacity(node.isMuted && !node.isSolo ? 0.72 : 0.96)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
    }

    private func ghostChip(systemImage: String, active: Bool, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(active ? .white : OmniTheme.textPrimary.opacity(0.85))
            .frame(width: 28, height: 28)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? tint.opacity(0.55) : OmniTheme.fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(active ? tint.opacity(0.9) : OmniTheme.strokeSoft, lineWidth: 1)
                    }
            }
    }

    private func controlButton(
        title: String,
        systemImage: String,
        active: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
            }
            .foregroundStyle(active ? .white : OmniTheme.textPrimary.opacity(0.85))
            .frame(width: 44, height: 36)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? tint.opacity(0.55) : OmniTheme.fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(active ? tint.opacity(0.9) : OmniTheme.strokeSoft, lineWidth: 1)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

/// Meter + dB caption for one app; the only part of a card that redraws at meter rate.
private struct AppLiveLevelRow: View {
    let feed: LiveLevelFeed
    let pid: pid_t
    let isActive: Bool

    var body: some View {
        LiveTimeline {
            let leveldB = feed.levels[pid] ?? -60
            HStack(spacing: 8) {
                AppPeakMeter(leveldB: leveldB, isActive: isActive)
                    .frame(height: 10)
                Text(Self.caption(leveldB: leveldB, isActive: isActive))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(OmniTheme.textSecondary)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                    .contentTransition(.identity)
            }
        }
    }

    private static func caption(leveldB: Float, isActive: Bool) -> String {
        guard isActive else { return "—" }
        if leveldB <= -48 { return "quiet" }
        return String(format: "%.0f", leveldB)
    }
}

/// Horizontal loudness meter. Uses RMS (how loud it sounds), not sample peak.
private struct AppPeakMeter: View {
    let leveldB: Float
    let isActive: Bool

    /// Map −48…0 dBFS → 0…1 so silence is empty and normal music sits mid–high (not pegged).
    private var fraction: CGFloat {
        guard isActive else { return 0 }
        let clamped = max(-48, min(0, leveldB))
        if clamped <= -47.5 { return 0 }
        return CGFloat((clamped + 48) / 48)
    }

    private var fill: Color {
        if !isActive { return OmniTheme.textSecondary.opacity(0.35) }
        if leveldB > -6 { return OmniTheme.coral }
        if leveldB > -14 { return OmniTheme.amber }
        return OmniTheme.mint
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(OmniTheme.fill)
                Capsule()
                    .fill(fill)
                    .frame(width: w * fraction)
            }
        }
        .overlay {
            Capsule()
                .strokeBorder(OmniTheme.strokeSoft, lineWidth: 1)
        }
        .help(
            isActive
            ? "How loud this app is right now (dBFS)."
            : "Turn On to route through OmniLevel and see live level."
        )
        .opacity(isActive ? 1 : 0.55)
        .transaction { $0.animation = nil }
    }
}
