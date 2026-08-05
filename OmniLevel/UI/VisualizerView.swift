import SwiftUI

enum VisualizerMode: String, CaseIterable, Identifiable {
    case spectrum = "Spectrum"
    case liquid = "Liquid"
    case mirror = "Mirror"

    var id: String { rawValue }
}

/// Display clock drives sampling + smoothing so motion is continuous and light.
struct VisualizerView: View {
    @ObservedObject var engine: AudioEngineController
    @State private var mode: VisualizerMode = .liquid
    @State private var bars: [Float] = Array(repeating: -80, count: 40)
    @State private var peaks: [Float] = Array(repeating: -80, count: 40)
    @State private var levels = AudioLevels.Snapshot.silence
    @State private var smoothL: CGFloat = 0
    @State private var smoothR: CGFloat = 0
    @State private var smoothPeakL: CGFloat = 0
    @State private var smoothPeakR: CGFloat = 0
    @State private var lastTick: Date = .now

    private let barCount = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            meters
                .frame(height: 40)
            spectrumSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 190)
        }
        .padding(16)
        .glassCard(cornerRadius: 20)
        .background {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                Color.clear
                    .onChange(of: timeline.date) { _, date in
                        tick(at: date)
                    }
            }
        }
        .onAppear {
            lastTick = .now
            tick(at: .now)
        }
    }

    private var header: some View {
        HStack {
            Text("Monitor")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(OmniTheme.textPrimary)
            Spacer()
            HStack(spacing: 0) {
                ForEach(VisualizerMode.allCases) { m in
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { mode = m }
                    } label: {
                        Text(m.rawValue)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(mode == m ? Color.black.opacity(0.82) : OmniTheme.textSecondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background {
                                if mode == m {
                                    Capsule()
                                        .fill(Color.white.opacity(0.92))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2.5)
            .background {
                Capsule()
                    .fill(Color.white.opacity(0.06))
                    .overlay { Capsule().strokeBorder(OmniTheme.strokeSoft, lineWidth: 1) }
            }
        }
    }

    private var meters: some View {
        HStack(spacing: 14) {
            meter(label: "L", level: smoothL, peak: smoothPeakL)
            meter(label: "R", level: smoothR, peak: smoothPeakR)
        }
    }

    private func meter(label: String, level: CGFloat, peak: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(OmniTheme.textSecondary)
                .frame(width: 10)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.black.opacity(0.28))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    OmniTheme.accent.opacity(0.35),
                                    OmniTheme.accent.opacity(0.95)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(2, geo.size.width * level))
                    // Soft peak marker
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 2, height: 8)
                        .offset(x: max(0, geo.size.width * peak - 1))
                }
            }
            .frame(height: 6)
        }
    }

    private var spectrumSurface: some View {
        Canvas { context, size in
            // Quiet floor
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(
                Path(roundedRect: bounds, cornerRadius: 14, style: .continuous),
                with: .color(Color.black.opacity(0.22))
            )

            // Soft baseline
            var base = Path()
            base.move(to: CGPoint(x: 12, y: size.height - 10))
            base.addLine(to: CGPoint(x: size.width - 12, y: size.height - 10))
            context.stroke(base, with: .color(.white.opacity(0.05)), lineWidth: 1)

            switch mode {
            case .spectrum:
                drawSpectrum(context: context, size: size)
            case .liquid:
                drawLiquid(context: context, size: size)
            case .mirror:
                drawMirror(context: context, size: size)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(OmniTheme.strokeSoft, lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.08), value: bars)
    }

    // MARK: - Draw modes (minimal)

    private func drawSpectrum(context: GraphicsContext, size: CGSize) {
        let count = bars.count
        guard count > 0 else { return }
        let inset: CGFloat = 10
        let usableW = size.width - inset * 2
        let gap: CGFloat = 2.5
        let w = max(2, (usableW - gap * CGFloat(count - 1)) / CGFloat(count))
        let maxH = size.height - 20

        for i in 0..<count {
            let unit = CGFloat(dbToUnit(bars[i]))
            let h = max(1.5, maxH * unit * 0.92)
            let x = inset + CGFloat(i) * (w + gap)
            let rect = CGRect(x: x, y: size.height - 10 - h, width: w, height: h)
            let path = Path(roundedRect: rect, cornerRadius: w * 0.35)

            context.fill(
                path,
                with: .linearGradient(
                    Gradient(colors: [
                        OmniTheme.accent.opacity(0.15 + unit * 0.35),
                        OmniTheme.accent.opacity(0.55 + unit * 0.4)
                    ]),
                    startPoint: CGPoint(x: x, y: size.height),
                    endPoint: CGPoint(x: x, y: size.height - h)
                )
            )

            // Peak tip
            if i < peaks.count {
                let pu = CGFloat(dbToUnit(peaks[i]))
                let py = size.height - 10 - maxH * pu * 0.92
                let tip = CGRect(x: x, y: py - 1, width: w, height: 1.5)
                context.fill(Path(tip), with: .color(Color.white.opacity(0.35 + pu * 0.35)))
            }
        }
    }

    private func drawLiquid(context: GraphicsContext, size: CGSize) {
        guard bars.count > 1 else { return }
        let inset: CGFloat = 8
        let maxH = size.height - 24
        let pts: [CGPoint] = bars.enumerated().map { i, db in
            let x = inset + (size.width - inset * 2) * CGFloat(i) / CGFloat(bars.count - 1)
            let y = size.height - 12 - maxH * CGFloat(dbToUnit(db)) * 0.9
            return CGPoint(x: x, y: y)
        }

        var path = Path()
        path.move(to: pts[0])
        for i in 1..<pts.count {
            let prev = pts[i - 1]
            let curr = pts[i]
            let mid = CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2)
            path.addQuadCurve(to: mid, control: prev)
        }
        if let last = pts.last { path.addLine(to: last) }

        // Fill under curve
        var fill = path
        fill.addLine(to: CGPoint(x: size.width - inset, y: size.height - 8))
        fill.addLine(to: CGPoint(x: inset, y: size.height - 8))
        fill.closeSubpath()
        context.fill(
            fill,
            with: .linearGradient(
                Gradient(colors: [
                    OmniTheme.accent.opacity(0.22),
                    OmniTheme.accent.opacity(0.02)
                ]),
                startPoint: CGPoint(x: size.width / 2, y: 0),
                endPoint: CGPoint(x: size.width / 2, y: size.height)
            )
        )

        context.stroke(
            path,
            with: .color(OmniTheme.accent.opacity(0.9)),
            style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
        )

        // Peak silhouette (thinner, quieter)
        if peaks.count == bars.count {
            var peakPath = Path()
            let ppts: [CGPoint] = peaks.enumerated().map { i, db in
                let x = inset + (size.width - inset * 2) * CGFloat(i) / CGFloat(peaks.count - 1)
                let y = size.height - 12 - maxH * CGFloat(dbToUnit(db)) * 0.9
                return CGPoint(x: x, y: y)
            }
            peakPath.move(to: ppts[0])
            for i in 1..<ppts.count {
                let prev = ppts[i - 1]
                let curr = ppts[i]
                peakPath.addQuadCurve(
                    to: CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2),
                    control: prev
                )
            }
            context.stroke(
                peakPath,
                with: .color(Color.white.opacity(0.12)),
                style: StrokeStyle(lineWidth: 1, lineCap: .round)
            )
        }
    }

    /// Symmetric spectrum — thin bands reflect over the mid-line (left ↔ right stereo feel).
    private func drawMirror(context: GraphicsContext, size: CGSize) {
        let count = bars.count
        guard count > 0 else { return }

        let inset: CGFloat = 12
        let midY = size.height * 0.5
        let usableW = size.width - inset * 2
        let gap: CGFloat = 2.2
        let w = max(1.8, (usableW - gap * CGFloat(count - 1)) / CGFloat(count))
        let maxHalf = size.height * 0.42

        // Soft horizon guide
        var guide = Path()
        guide.move(to: CGPoint(x: inset, y: midY))
        guide.addLine(to: CGPoint(x: size.width - inset, y: midY))
        context.stroke(guide, with: .color(.white.opacity(0.06)), lineWidth: 1)

        for i in 0..<count {
            let unit = CGFloat(dbToUnit(bars[i]))
            let half = max(1.2, maxHalf * unit)
            let x = inset + CGFloat(i) * (w + gap)

            // Upper lobe
            let top = CGRect(x: x, y: midY - half, width: w, height: half)
            // Lower lobe (mirror)
            let bot = CGRect(x: x, y: midY, width: w, height: half)

            let upper = Path(roundedRect: top, cornerRadius: w * 0.4, style: .continuous)
            let lower = Path(roundedRect: bot, cornerRadius: w * 0.4, style: .continuous)

            context.fill(
                upper,
                with: .linearGradient(
                    Gradient(colors: [
                        OmniTheme.accent.opacity(0.15 + unit * 0.55),
                        OmniTheme.accent.opacity(0.05)
                    ]),
                    startPoint: CGPoint(x: x, y: midY - half),
                    endPoint: CGPoint(x: x, y: midY)
                )
            )
            context.fill(
                lower,
                with: .linearGradient(
                    Gradient(colors: [
                        OmniTheme.mint.opacity(0.05),
                        OmniTheme.mint.opacity(0.12 + unit * 0.4)
                    ]),
                    startPoint: CGPoint(x: x, y: midY),
                    endPoint: CGPoint(x: x, y: midY + half)
                )
            )

            // Peak whiskers (quiet)
            if i < peaks.count {
                let pu = CGFloat(dbToUnit(peaks[i]))
                let ph = maxHalf * pu
                let tipTop = CGRect(x: x, y: midY - ph - 1, width: w, height: 1.2)
                let tipBot = CGRect(x: x, y: midY + ph, width: w, height: 1.2)
                context.fill(Path(tipTop), with: .color(Color.white.opacity(0.22 + pu * 0.25)))
                context.fill(Path(tipBot), with: .color(Color.white.opacity(0.12 + pu * 0.15)))
            }
        }
    }

    // MARK: - Tick

    private func tick(at date: Date) {
        let dt = Float(min(0.05, max(1.0 / 120.0, date.timeIntervalSince(lastTick))))
        lastTick = date

        // Spectrum + peak trails (analyzer owns smoothing)
        bars = engine.spectrum.logBars(count: barCount, dt: dt)
        peaks = engine.spectrum.peakHoldBars()

        // Meters with independent ease (UI-only)
        let snap = engine.levels.snapshot()
        levels = snap
        let targetL = CGFloat(dbToUnit(snap.rmsLeft))
        let targetR = CGFloat(dbToUnit(snap.rmsRight))
        let targetPL = CGFloat(dbToUnit(snap.peakLeft))
        let targetPR = CGFloat(dbToUnit(snap.peakRight))
        let a = CGFloat(1 - exp(-Double(dt) / 0.04))
        let ap = CGFloat(1 - exp(-Double(dt) / 0.08))
        smoothL += (targetL - smoothL) * a
        smoothR += (targetR - smoothR) * a
        smoothPeakL += (targetPL - smoothPeakL) * ap
        smoothPeakR += (targetPR - smoothPeakR) * ap
    }

    private func dbToUnit(_ db: Float) -> Float {
        let clamped = max(-72, min(0, db))
        // Gentle perceptual curve
        let linear = (clamped + 72) / 72
        return pow(linear, 0.85)
    }
}
