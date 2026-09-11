import AppKit
import SwiftUI

/// SwiftUI content clipped to a Dynamic Island–style notch hull.
///
/// Expand/collapse is a single clipped morph: the black hull grows/shrinks while
/// tray content is revealed or sheared away by the clip — never layout-compressed
/// inside a shrinking VStack (that was the laggy / “weird” collapse).
struct NotchNowPlayingRootView: View {
    @ObservedObject var viewModel: NotchNowPlayingViewModel
    @ObservedObject private var service: NowPlayingService

    init(viewModel: NotchNowPlayingViewModel) {
        self.viewModel = viewModel
        self._service = ObservedObject(wrappedValue: viewModel.service)
    }

    private var pureBlack: Color { Color(red: 0, green: 0, blue: 0) }

    private var collapsedWingWidth: CGFloat {
        // Outer pad + 18pt art + gap + live dot + inner pad from camera housing.
        service.players.count > 1 ? 50 : 46
    }

    private var collapsedWidth: CGFloat {
        viewModel.geometry.width + collapsedWingWidth * 2
    }

    private var expandedWidth: CGFloat {
        let count = max(service.players.count, 1)
        return max(collapsedWidth, count > 1 ? 340 : 300)
    }

    private var expandedBodyHeight: CGFloat {
        let count = max(service.players.count, 1)
        let row: CGFloat = 56
        let body = CGFloat(count) * row + CGFloat(max(count - 1, 0)) * 6 + 12
        return min(body, 110)
    }

    private var islandWidth: CGFloat {
        viewModel.isExpanded ? expandedWidth : collapsedWidth
    }

    private var islandHeight: CGFloat {
        viewModel.isExpanded
            ? viewModel.geometry.height + expandedBodyHeight
            : viewModel.geometry.height
    }

    private var topRadius: CGFloat { viewModel.isExpanded ? 8 : 3 }
    private var bottomRadius: CGFloat {
        viewModel.isExpanded
            ? 20
            : min(10, max(6, viewModel.geometry.height * 0.28))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear

            island
                .frame(width: islandWidth, height: islandHeight, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .preferredColorScheme(.dark)
    }

    private var island: some View {
        let shape = NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)

        return ZStack(alignment: .top) {
            shape.fill(pureBlack)

            // Collapsed wings live only in the camera band.
            collapsedStrip
                .frame(height: viewModel.geometry.height)
                .opacity(viewModel.isExpanded ? 0 : 1)
                .allowsHitTesting(!viewModel.isExpanded)

            // Tray is overlaid below the band at a fixed layout size so collapsing
            // only clips it away — no VStack compression / content squish.
            expandedTray
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 8)
                .frame(width: expandedWidth, height: expandedBodyHeight, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.top, viewModel.geometry.height)
                .allowsHitTesting(viewModel.isExpanded)
        }
        .frame(width: islandWidth, height: islandHeight, alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
    }

    // MARK: - Collapsed wings

    private var collapsedStrip: some View {
        HStack(spacing: 0) {
            leftWing
                .frame(width: collapsedWingWidth, height: viewModel.geometry.height)

            // Exact camera cutout — wings never steal this space.
            Color.clear
                .frame(width: viewModel.geometry.width, height: viewModel.geometry.height)

            rightWing
                .frame(width: collapsedWingWidth, height: viewModel.geometry.height)
        }
        .frame(width: collapsedWidth, height: viewModel.geometry.height)
    }

    /// Artwork tucked against the left of the camera housing.
    private var leftWing: some View {
        HStack(spacing: 5) {
            if let first = service.players.first {
                miniArt(first, size: 18)
                if first.isPlaying {
                    LiveDot(color: tint(for: first))
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.leading, 10)
        .padding(.trailing, 8)
    }

    /// App icon / second player tucked against the right of the camera housing.
    private var rightWing: some View {
        HStack(spacing: 5) {
            if service.players.count > 1, let second = service.players.last {
                if second.isPlaying {
                    LiveDot(color: tint(for: second))
                }
                miniArt(second, size: 18)
            } else if let first = service.players.first {
                miniAppIcon(first, size: 16)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 8)
        .padding(.trailing, 10)
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
        .fixedSize()
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
        .fixedSize()
    }

    // MARK: - Expanded tray

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
