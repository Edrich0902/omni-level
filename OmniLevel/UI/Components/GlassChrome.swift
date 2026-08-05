import SwiftUI

// MARK: - Design tokens

enum OmniTheme {
    static let accent = Color(red: 0.35, green: 0.78, blue: 0.88)
    static let accentDeep = Color(red: 0.22, green: 0.62, blue: 0.72)
    static let mint = Color(red: 0.45, green: 0.86, blue: 0.72)
    static let coral = Color(red: 0.96, green: 0.52, blue: 0.38)
    static let amber = Color(red: 0.98, green: 0.78, blue: 0.32)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let stroke = Color.white.opacity(0.18)
    static let strokeSoft = Color.white.opacity(0.10)
    static let fill = Color.white.opacity(0.06)
    static let fillStrong = Color.white.opacity(0.10)
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
                                    Color.white.opacity(0.12),
                                    Color.white.opacity(0.03),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.35),
                                    Color.white.opacity(0.08),
                                    Color.white.opacity(0.18)
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
            // withinWindow material so liquid glass reads clearly inside NSPopover
            VisualEffectBackground(material: .sidebar, blendingMode: .withinWindow)
                .ignoresSafeArea()

            // Atmospheric depth wash
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.16, blue: 0.20).opacity(0.45),
                    Color(red: 0.06, green: 0.09, blue: 0.12).opacity(0.55),
                    Color(red: 0.07, green: 0.13, blue: 0.15).opacity(0.48)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Soft light orbs (static — no continuous animation under the whole tree)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [OmniTheme.accent.opacity(0.28), .clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: 180
                    )
                )
                .frame(width: 320, height: 320)
                .offset(x: 8, y: -60)
                .blur(radius: 8)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [OmniTheme.mint.opacity(0.18), .clear],
                        center: .center,
                        startRadius: 5,
                        endRadius: 160
                    )
                )
                .frame(width: 280, height: 280)
                .offset(x: 20, y: 180)
                .blur(radius: 12)

            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.28), .clear, Color.white.opacity(0.1)],
                        startPoint: .top,
                        endPoint: .bottom
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
                    .fill(Color.black.opacity(0.32))
                    .frame(width: trackW)
                    .overlay {
                        Capsule()
                            .strokeBorder(OmniTheme.strokeSoft, lineWidth: 1)
                    }

                // Input spectrum (pre-EQ) — soft wider glow from bottom
                spectrumFill(
                    level: inputLevel,
                    height: h,
                    width: trackW + 4,
                    colors: [
                        Color.white.opacity(0.04),
                        Color.white.opacity(0.18 + inputLevel * 0.22)
                    ]
                )
                .position(x: cx, y: h - (h * min(1, max(0, inputLevel)) * 0.92) / 2)

                // Output spectrum (post-EQ) — accent energy from bottom
                spectrumFill(
                    level: outputLevel,
                    height: h,
                    width: trackW - 1,
                    colors: [
                        OmniTheme.accent.opacity(0.12),
                        OmniTheme.accent.opacity(0.55 + outputLevel * 0.4),
                        OmniTheme.mint.opacity(0.75)
                    ]
                )
                .position(x: cx, y: h - (h * min(1, max(0, outputLevel)) * 0.92) / 2)

                // Gain fill from centre 0 dB to thumb
                let fillTop = min(y, mid)
                let fillBottom = max(y, mid)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                OmniTheme.accent.opacity(0.85),
                                OmniTheme.mint.opacity(0.9)
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 3, height: max(2, fillBottom - fillTop))
                    .position(x: cx, y: (fillTop + fillBottom) / 2)
                    .opacity(0.9)

                // Center zero line
                Rectangle()
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 14, height: 1)
                    .position(x: cx, y: mid)

                // Thumb
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white, Color.white.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 15, height: 15)
                    .shadow(color: OmniTheme.accent.opacity(0.4 + outputLevel * 0.35), radius: 5, y: 1)
                    .overlay {
                        Circle().strokeBorder(OmniTheme.accent.opacity(0.55), lineWidth: 1)
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

    private func spectrumFill(
        level: CGFloat,
        height: CGFloat,
        width: CGFloat,
        colors: [Color]
    ) -> some View {
        let unit = min(1, max(0, level))
        let fillH = max(1.5, height * unit * 0.92)
        return Capsule()
            .fill(
                LinearGradient(
                    colors: colors,
                    startPoint: .bottom,
                    endPoint: .top
                )
            )
            .frame(width: width, height: fillH)
            .opacity(unit > 0.02 ? 1 : 0)
    }
}
