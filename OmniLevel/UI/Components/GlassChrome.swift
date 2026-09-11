import SwiftUI

// MARK: - Design tokens

enum OmniTheme {
    /// Spotify green accent.
    static let accent = Color(red: 0.114, green: 0.725, blue: 0.329)
    static let accentDeep = Color(red: 0.08, green: 0.52, blue: 0.24)
    static let mint = Color(red: 0.30, green: 0.90, blue: 0.52)
    static let coral = Color(red: 0.96, green: 0.42, blue: 0.38)
    static let amber = Color(red: 0.98, green: 0.78, blue: 0.32)
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.52)
    static let stroke = Color.white.opacity(0.14)
    static let strokeSoft = Color.white.opacity(0.08)
    static let fill = Color.white.opacity(0.055)
    static let fillStrong = Color.white.opacity(0.09)
    /// Near-black base layers for a dark Spotify-like surface.
    static let bgDeep = Color(red: 0.04, green: 0.05, blue: 0.05)
    static let bgMid = Color(red: 0.07, green: 0.08, blue: 0.08)
}

// MARK: - NSVisualEffect glass host

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Glass surfaces

struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16
    var elevated: Bool = true

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.08),
                                    OmniTheme.accent.opacity(0.04),
                                    Color.black.opacity(0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    OmniTheme.accent.opacity(0.35),
                                    Color.white.opacity(0.08),
                                    OmniTheme.accent.opacity(0.14)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: elevated ? .black.opacity(0.22) : .clear, radius: elevated ? 16 : 0, y: elevated ? 6 : 0)
            }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 16, elevated: Bool = true) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, elevated: elevated))
    }
}

struct GlassBackground: View {
    var body: some View {
        ZStack {
            // Deep black glass base
            VisualEffectBackground(material: .hudWindow, blendingMode: .withinWindow)
                .ignoresSafeArea()

            OmniTheme.bgDeep.opacity(0.72)
                .ignoresSafeArea()

            // Subtle black depth
            LinearGradient(
                colors: [
                    Color.black.opacity(0.55),
                    OmniTheme.bgMid.opacity(0.45),
                    Color.black.opacity(0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Spotify green liquid wash
            Circle()
                .fill(
                    RadialGradient(
                        colors: [OmniTheme.accent.opacity(0.34), OmniTheme.accent.opacity(0.06), .clear],
                        center: .center,
                        startRadius: 8,
                        endRadius: 200
                    )
                )
                .frame(width: 340, height: 340)
                .offset(x: 30, y: -90)
                .blur(radius: 10)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [OmniTheme.accentDeep.opacity(0.28), .clear],
                        center: .center,
                        startRadius: 4,
                        endRadius: 160
                    )
                )
                .frame(width: 260, height: 260)
                .offset(x: -70, y: 210)
                .blur(radius: 14)

            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            OmniTheme.accent.opacity(0.22),
                            Color.white.opacity(0.06),
                            OmniTheme.accent.opacity(0.1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .ignoresSafeArea()
        }
    }
}

// MARK: - Controls

struct GlassIconButton: View {
    let systemName: String
    var active: Bool = false
    var tint: Color = OmniTheme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? tint : OmniTheme.textPrimary)
                .frame(width: 30, height: 30)
                .background {
                    Circle()
                        .fill(active ? tint.opacity(0.22) : OmniTheme.fill)
                        .overlay {
                            Circle()
                                .strokeBorder(active ? tint.opacity(0.55) : OmniTheme.strokeSoft, lineWidth: 1)
                        }
                }
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
    }
}

struct GlassChip: View {
    let title: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(OmniTheme.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(OmniTheme.fillStrong)
                .overlay {
                    Capsule().strokeBorder(OmniTheme.stroke, lineWidth: 1)
                }
        }
    }
}

struct SectionLabel: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(OmniTheme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.8)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(OmniTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(OmniTheme.accent.opacity(0.15), in: Capsule())
            }
        }
    }
}

/// Tall custom vertical gain fader for precise EQ control.
struct VerticalGainSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -24...24
    var trackHeight: CGFloat = 168
    /// 0...1 program energy pre-EQ at this band.
    var inputLevel: CGFloat = 0
    /// 0...1 program energy post-EQ at this band.
    var outputLevel: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let t = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let y = h * (1 - CGFloat(t))
            let mid = h / 2
            let trackW: CGFloat = 10
            let cx = geo.size.width / 2

            ZStack {
                // Track well
                Capsule()
                    .fill(Color.black.opacity(0.38))
                    .frame(width: trackW + 2)
                    .overlay {
                        Capsule()
                            .strokeBorder(OmniTheme.strokeSoft, lineWidth: 1)
                    }

                // Live meters — cool / warm so they never fight the mint gain control.
                let inH = max(0, h * min(1, max(0, inputLevel)) * 0.92)
                let outH = max(0, h * min(1, max(0, outputLevel)) * 0.92)
                let barW: CGFloat = 3
                // Input (pre-EQ) — left, cool blue
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.35, green: 0.55, blue: 0.85).opacity(0.35),
                                Color(red: 0.55, green: 0.78, blue: 1.0).opacity(0.9)
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: barW, height: inH > 1 ? inH : 0)
                    .position(x: cx - 3.2, y: h - inH / 2)
                    .opacity(inH > 2 ? 0.95 : 0)
                // Output (post-EQ) — right, amber
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                OmniTheme.amber.opacity(0.4),
                                OmniTheme.amber.opacity(0.95),
                                Color(red: 1.0, green: 0.72, blue: 0.35)
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: barW, height: outH > 1 ? outH : 0)
                    .position(x: cx + 3.2, y: h - outH / 2)
                    .opacity(outH > 2 ? 0.95 : 0)

                // Gain fill (mint) — control only, sits above meters
                let fillTop = min(y, mid)
                let fillBottom = max(y, mid)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                OmniTheme.mint.opacity(0.95),
                                OmniTheme.accent.opacity(0.9)
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 2.5, height: max(2, fillBottom - fillTop))
                    .position(x: cx, y: (fillTop + fillBottom) / 2)
                    .opacity(0.95)

                // Center zero line
                Rectangle()
                    .fill(Color.white.opacity(0.32))
                    .frame(width: 14, height: 1)
                    .position(x: cx, y: mid)

                // Thumb — neutral white, no mint glow (meters own cool/warm)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white, Color.white.opacity(0.88)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 15, height: 15)
                    .shadow(color: Color.black.opacity(0.45), radius: 3, y: 1)
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.75), lineWidth: 1)
                    }
                    .position(x: cx, y: y)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let clampedY = max(0, min(h, drag.location.y))
                        let nt = 1 - Double(clampedY / h)
                        let raw = range.lowerBound + nt * (range.upperBound - range.lowerBound)
                        if abs(raw) < 0.35 {
                            value = 0
                        } else {
                            value = max(range.lowerBound, min(range.upperBound, raw))
                        }
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    value = 0
                }
            }
        }
        .frame(height: trackHeight)
        // No implicit animation on level ticks — Canvas-like discrete updates only.
    }
}
