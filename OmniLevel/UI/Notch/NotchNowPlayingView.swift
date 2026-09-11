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

    private var topRadius: CGFloat { viewModel.isExpanded ? 8 : 3 }
    private var bottomRadius: CGFloat {
        if viewModel.isExpanded { return 16 }
        return min(10, max(6, viewModel.geometry.height * 0.28))
    }

    private var pureBlack: Color { Color(red: 0, green: 0, blue: 0) }

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)
                .fill(pureBlack)

            VStack(spacing: 0) {
                Color.clear
                    .frame(height: viewModel.geometry.height)
                    .overlay {
                        if !viewModel.isExpanded {
                            collapsedStrip
                        }
                    }

                if viewModel.isExpanded {
                    expandedTray
                        .padding(.horizontal, 10)
                        .padding(.top, 2)
                        .padding(.bottom, 8)
                        // Opacity only — panel frame animation is owned by AppKit.
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius))
        .background(Color.clear)
        .preferredColorScheme(.dark)
        .compositingGroup()
        .animation(.easeOut(duration: 0.12), value: viewModel.isExpanded)
        .animation(.easeOut(duration: 0.15), value: service.players.map(\.id))
    }

    // MARK: - Collapsed wings

    private var collapsedStrip: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if let first = service.players.first {
                    miniArt(first, size: 16)
                    if first.isPlaying {
                        LiveDot(color: tint(for: first))
                    }
                }
                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity)

            Color.clear
                .frame(width: max(viewModel.geometry.width - 4, 90))

            HStack(spacing: 6) {
                Spacer(minLength: 4)
                if service.players.count > 1, let second = service.players.last {
                    if second.isPlaying {
                        LiveDot(color: tint(for: second))
                    }
                    miniArt(second, size: 16)
                } else if let first = service.players.first {
                    miniAppIcon(first, size: 14)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
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

    // MARK: - Expanded tray (compact single row)

    private var expandedTray: some View {
        VStack(spacing: 6) {
            ForEach(service.players) { item in
                expandedPlayer(item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func expandedPlayer(_ item: NowPlayingItem) -> some View {
        let accent = tint(for: item)

        return HStack(alignment: .center, spacing: 10) {
            artwork(item, size: 36, accent: accent)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .lineLimit(1)
                Text(item.artist.isEmpty ? item.appName : item.artist)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            transport(item, accent: accent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(accent.opacity(0.25), lineWidth: 1)
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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(accent.opacity(0.75))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func transport(_ item: NowPlayingItem, accent: Color) -> some View {
        HStack(spacing: 4) {
            iconButton("backward.fill", size: 9, accent: accent) { service.previous(item) }
            iconButton(item.isPlaying ? "pause.fill" : "play.fill", size: 10, filled: true, accent: accent) {
                service.togglePlayPause(item)
            }
            iconButton("forward.fill", size: 9, accent: accent) { service.next(item) }
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
                .frame(width: filled ? 26 : 22, height: filled ? 26 : 22)
                .background {
                    if filled {
                        Circle().fill(Color.white)
                    } else {
                        Circle().fill(Color.white.opacity(0.08))
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func tint(for item: NowPlayingItem) -> Color {
        switch item.source {
        case .spotify: return Color(red: 0.114, green: 0.725, blue: 0.329)
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
            .frame(width: 4, height: 4)
            .shadow(color: color.opacity(0.8), radius: 2)
    }
}
