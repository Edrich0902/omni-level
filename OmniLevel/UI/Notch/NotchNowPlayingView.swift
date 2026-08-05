import AppKit
import SwiftUI

/// SwiftUI content clipped to a Dynamic Island–style notch hull.
/// Pure black, proportional layout — hangs from the physical camera housing.
struct NotchNowPlayingRootView: View {
    @ObservedObject var viewModel: NotchNowPlayingViewModel
    @ObservedObject private var service: NowPlayingService

    init(viewModel: NotchNowPlayingViewModel) {
        self.viewModel = viewModel
        self._service = ObservedObject(wrappedValue: viewModel.service)
    }

    /// Match hardware notch corners more closely when closed; slightly larger when open.
    private var topRadius: CGFloat { viewModel.isExpanded ? 12 : 5 }
    private var bottomRadius: CGFloat { viewModel.isExpanded ? 26 : 14 }

    private var pureBlack: Color { Color(red: 0, green: 0, blue: 0) }

    var body: some View {
        ZStack(alignment: .top) {
            // Base is absolute black so the island merges with the hardware notch.
            NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)
                .fill(pureBlack)

            VStack(spacing: 0) {
                // Band that covers the physical cutout height.
                Color.clear
                    .frame(height: viewModel.geometry.height)
                    .overlay {
                        if !viewModel.isExpanded {
                            collapsedStrip
                                .padding(.horizontal, 14)
                        }
                    }

                if viewModel.isExpanded {
                    expandedTray
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 16)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .preferredColorScheme(.dark)
        .compositingGroup()
        .animation(.spring(response: 0.42, dampingFraction: 0.9), value: viewModel.isExpanded)
        .animation(.easeOut(duration: 0.2), value: service.players.map(\.id))
    }

    // MARK: - Collapsed wings

    private var collapsedStrip: some View {
        HStack(spacing: 0) {
            // Left wing — primary art + live indicator
            HStack(spacing: 8) {
                if let first = service.players.first {
                    miniArt(first, size: 20)
                    if first.isPlaying {
                        LiveDot(color: tint(for: first))
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            // Leave the camera housing free.
            Color.clear
                .frame(width: max(viewModel.geometry.width - 8, 100))

            // Right wing — second source art, or primary app icon (compact)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if service.players.count > 1, let second = service.players.last {
                    if second.isPlaying {
                        LiveDot(color: tint(for: second))
                    }
                    miniArt(second, size: 20)
                } else if let first = service.players.first {
                    miniAppIcon(first, size: 16)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func miniArt(_ item: NowPlayingItem, size: CGFloat) -> some View {
        Group {
            if let art = item.artwork {
                Image(nsImage: art)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    Image(systemName: item.source == .spotify ? "music.note" : "globe")
                        .font(.system(size: size * 0.4, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private func miniAppIcon(_ item: NowPlayingItem, size: CGFloat) -> some View {
        Group {
            if let icon = item.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: item.source == .spotify ? "music.note" : "globe")
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(tint(for: item).opacity(0.9))
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    // MARK: - Expanded tray

    private var expandedTray: some View {
        VStack(spacing: 12) {
            ForEach(service.players) { item in
                expandedPlayer(item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func expandedPlayer(_ item: NowPlayingItem) -> some View {
        let accent = tint(for: item)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                artwork(item, size: 48, accent: accent)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if let icon = item.appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 11, height: 11)
                                .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                        }
                        Text(item.appName)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(0.3)
                            .foregroundStyle(accent.opacity(0.95))
                            .textCase(.uppercase)
                        if item.isPlaying {
                            Image(systemName: "waveform")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(accent.opacity(0.85))
                                .symbolEffect(.variableColor.iterative, isActive: true)
                        }
                    }

                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.95))
                        .lineLimit(1)

                    if !item.artist.isEmpty {
                        Text(item.artist)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                transport(item, accent: accent)
            }

            if item.hasProgress {
                NowPlayingSeekBar(item: item, accent: accent) { seconds in
                    service.seek(item, to: seconds)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                // Soft source wash (Spotify green / system cyan) — stays black-dominant
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(0.10),
                                accent.opacity(0.02),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                accent.opacity(0.45),
                                accent.opacity(0.12),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        }
    }

    private func artwork(_ item: NowPlayingItem, size: CGFloat, accent: Color) -> some View {
        Group {
            if let art = item.artwork {
                Image(nsImage: art)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    accent.opacity(0.12)
                    Image(systemName: item.source == .spotify ? "music.note.list" : "globe")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(accent.opacity(0.75))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(accent.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: accent.opacity(item.isPlaying ? 0.3 : 0.12), radius: item.isPlaying ? 8 : 4, y: 1)
    }

    private func transport(_ item: NowPlayingItem, accent: Color) -> some View {
        HStack(spacing: 6) {
            iconButton("backward.fill", size: 11, accent: accent) { service.previous(item) }
            iconButton(item.isPlaying ? "pause.fill" : "play.fill", size: 12, filled: true, accent: accent) {
                service.togglePlayPause(item)
            }
            iconButton("forward.fill", size: 11, accent: accent) { service.next(item) }
        }
    }

    private func iconButton(
        _ systemName: String,
        size: CGFloat,
        filled: Bool = false,
        accent: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(filled ? pureBlack : Color.white.opacity(0.9))
                .frame(width: filled ? 32 : 28, height: filled ? 32 : 28)
                .background {
                    if filled {
                        Circle()
                            .fill(Color.white)
                            .shadow(color: accent.opacity(0.35), radius: 6, y: 1)
                    } else {
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func tint(for item: NowPlayingItem) -> Color {
        switch item.source {
        case .spotify: return Color(red: 0.18, green: 0.84, blue: 0.45)
        case .system: return OmniTheme.accent
        }
    }
}

// MARK: - Live indicator

private struct LiveDot: View {
    var color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .shadow(color: color.opacity(0.8), radius: 3)
    }
}
