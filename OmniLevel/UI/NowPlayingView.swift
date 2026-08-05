import AppKit
import SwiftUI

/// Always-on Now Playing strip: one card per active source (Spotify + browser/system).
struct NowPlayingSection: View {
    @ObservedObject var service: NowPlayingService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Now Playing")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(OmniTheme.textSecondary)
                Spacer()
                if service.players.isEmpty {
                    Text("Nothing active")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(OmniTheme.textSecondary.opacity(0.7))
                }
            }

            if let hint = service.automationHint, service.players.isEmpty || service.players.allSatisfy({ $0.source != .spotify }) {
                Text(hint)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(OmniTheme.amber.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if service.players.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(service.players) { item in
                        NowPlayingCard(
                            item: item,
                            onPlayPause: { service.togglePlayPause(item) },
                            onPrevious: { service.previous(item) },
                            onNext: { service.next(item) },
                            onSeek: { service.seek(item, to: $0) }
                        )
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(OmniTheme.textSecondary)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text("Start Spotify or a browser video")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(OmniTheme.textPrimary.opacity(0.85))
                Text("Each source shows up with artwork and transport")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(OmniTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(OmniTheme.strokeSoft, lineWidth: 1)
                }
        }
    }
}

struct NowPlayingCard: View {
    let item: NowPlayingItem
    var onPlayPause: () -> Void
    var onPrevious: () -> Void
    var onNext: () -> Void
    var onSeek: (TimeInterval) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                artwork
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let icon = item.appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 12, height: 12)
                                .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                        }
                        Text(item.appName)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(sourceTint)
                            .lineLimit(1)
                        if item.isPlaying {
                            Image(systemName: "waveform")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(sourceTint.opacity(0.9))
                                .symbolEffect(.variableColor.iterative, isActive: item.isPlaying)
                        }
                    }

                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(OmniTheme.textPrimary)
                        .lineLimit(1)

                    if !item.artist.isEmpty {
                        Text(item.artist)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(OmniTheme.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                transport
            }

            if item.hasProgress {
                NowPlayingSeekBar(item: item, accent: sourceTint, onSeek: onSeek)
            }
        }
        .padding(12)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                if let art = item.artwork {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.clear,
                                    Color(nsColor: art.averageColor()).opacity(0.16)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [sourceTint.opacity(0.3), OmniTheme.strokeSoft],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        }
        .animation(.easeOut(duration: 0.2), value: item.isPlaying)
        .animation(.easeOut(duration: 0.25), value: item.title)
    }

    private var sourceTint: Color {
        switch item.source {
        case .spotify: return Color(red: 0.114, green: 0.725, blue: 0.329)
        case .system: return OmniTheme.accent
        }
    }

    @ViewBuilder
    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.35))
            if let artwork = item.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: item.source == .spotify ? "music.note.list" : "globe")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(sourceTint.opacity(0.8))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: sourceTint.opacity(item.isPlaying ? 0.3 : 0.08), radius: item.isPlaying ? 8 : 3, y: 2)
    }

    private var transport: some View {
        HStack(spacing: 4) {
            transportButton(systemName: "backward.fill", action: onPrevious)
            transportButton(
                systemName: item.isPlaying ? "pause.fill" : "play.fill",
                emphasized: true,
                action: onPlayPause
            )
            transportButton(systemName: "forward.fill", action: onNext)
        }
    }

    private func transportButton(systemName: String, emphasized: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: emphasized ? 13 : 11, weight: .semibold))
                .foregroundStyle(emphasized ? Color.black.opacity(0.85) : OmniTheme.textPrimary)
                .frame(width: emphasized ? 34 : 28, height: emphasized ? 34 : 28)
                .background {
                    if emphasized {
                        Circle()
                            .fill(Color.white)
                    } else {
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tiny helper for artwork-tinted wash

private extension NSImage {
    func averageColor() -> NSColor {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let color = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
        else {
            return NSColor(calibratedWhite: 0.2, alpha: 1)
        }
        return color
    }
}
