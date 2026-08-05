import AppKit
import SwiftUI

struct AppVolumeCard: View {
    let node: AppAudioNode
    var onVolume: (Float) -> Void
    var onPan: (Float) -> Void
    var onMute: () -> Void
    var onSolo: () -> Void
    var onToggleTap: () -> Void

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
                    Text(node.appName)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(OmniTheme.textPrimary)
                        .lineLimit(1)
                    Text(node.isTapped ? "Through OmniLevel" : "Bypassing OmniLevel")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(node.isTapped ? OmniTheme.mint : OmniTheme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

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
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 14, elevated: false)
        .opacity(node.isMuted && !node.isSolo ? 0.72 : 1)
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
