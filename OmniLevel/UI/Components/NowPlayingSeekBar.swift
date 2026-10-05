import SwiftUI

/// Minimal seek bar — live progress with optional scrub-to-seek.
struct NowPlayingSeekBar: View {
    let item: NowPlayingItem
    var accent: Color
    var onSeek: (TimeInterval) -> Void

    @State private var isDragging = false
    @State private var dragFraction: Double = 0
    @Environment(\.liveUpdatesEnabled) private var liveUpdatesEnabled

    var body: some View {
        TimelineView(.periodic(from: .now, by: item.isPlaying && !isDragging && liveUpdatesEnabled ? 0.5 : 120)) { context in
            let live = item.livePosition(at: context.date)
            let duration = item.duration ?? 0
            let fraction = isDragging
                ? dragFraction
                : item.progressFraction(at: context.date)
            let displayed = isDragging ? dragFraction * duration : live

            VStack(spacing: 4) {
                GeometryReader { geo in
                    let w = max(geo.size.width, 1)
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.12))
                            .frame(height: 3)
                        Capsule(style: .continuous)
                            .fill(accent.opacity(0.95))
                            .frame(width: max(3, w * fraction), height: 3)
                        Circle()
                            .fill(Color.white)
                            .frame(width: isDragging ? 9 : 7, height: isDragging ? 9 : 7)
                            .offset(x: max(0, min(w - 7, w * fraction - 3.5)))
                            .opacity(isDragging || item.canSeek ? 1 : 0.85)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard item.canSeek, duration > 0 else { return }
                                isDragging = true
                                dragFraction = min(max(value.location.x / w, 0), 1)
                            }
                            .onEnded { value in
                                guard item.canSeek, duration > 0 else { return }
                                let f = min(max(value.location.x / w, 0), 1)
                                dragFraction = f
                                onSeek(f * duration)
                                isDragging = false
                            }
                    )
                }
                .frame(height: 12)

                HStack {
                    Text(formatTime(displayed))
                        .monospacedDigit()
                    Spacer()
                    Text(formatTime(duration))
                        .monospacedDigit()
                }
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.4))
            }
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t.rounded(.down))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
