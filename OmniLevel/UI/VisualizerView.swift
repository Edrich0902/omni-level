import SwiftUI

enum VisualizerMode: String, CaseIterable, Identifiable {
    case spectrum = "Spectrum"
    case liquid = "Liquid"
    case mirror = "Mirror"
    case rta = "RTA"
    case spectrogram = "Spectro"
    case scope = "Scope"

    var id: String { rawValue }

    var supportsEQOverlay: Bool {
        switch self {
        case .spectrum, .rta, .spectrogram: return true
        default: return false
        }
    }
}

enum RTABallisticsUI: String, CaseIterable, Identifiable {
    case fast = "Fast"
    case slow = "Slow"
    case peakHold = "Hold"

    var id: String { rawValue }

    var dsp: SpectrumAnalyzer.RTABallistics {
        switch self {
        case .fast: return .fast
        case .slow: return .slow
        case .peakHold: return .peakHold
        }
    }
}

/// Monitor analyzer suite — meters, viz modes, loudness history, session stats.
struct VisualizerView: View {
    @ObservedObject var engine: AudioEngineController
    @ObservedObject var tapManager: AppAudioTapManager
    var isActive: Bool = true

    @State private var mode: VisualizerMode = .liquid
    @State private var rtaBallistics: RTABallisticsUI = .fast
    @State private var showEQCurve = true
    @State private var historyUsesLUFS = true
    @Environment(\.liveUpdatesEnabled) private var liveUpdatesEnabled

    /// Per-tick data. Not observed here — only the live sections redraw at display rate,
    /// so the header and mode picker are never rebuilt by meter ticks.
    @StateObject private var live = MonitorLive()

    private var bars: [Float] { live.bars }
    private var peaks: [Float] { live.peaks }
    private var rtaBars: [Float] { live.rtaBars }
    private var mix: MixAnalyzer.Snapshot { live.mix }
    private var gr: AutoPreAmpLimiter.GRSnapshot { live.gr }
    private var gonio: [MixAnalyzer.GoniometerPoint] { live.gonio }
    private var spectroColumns: [[Float]] { live.spectroColumns }
    private var eqCurve: [(frequency: Float, magnitudedB: Float)] { live.eqCurve }

    private let barCount = 40
    private let spectroWidth = 96
    private let spectroBins = 64

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                LiveSection(feed: live.dashboard) { meterDashboard }
                modeChrome
                LiveSection(feed: live.surface) {
                    spectrumSurface
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                }
                LiveSection(feed: live.dashboard) {
                    loudnessHistory
                        .frame(height: 56)
                    sessionFooter
                }
            }
            .padding(16)
        }
        .glassCard(cornerRadius: 20)
        .background {
            TimelineView(
                .animation(
                    minimumInterval: isActive ? 1.0 / 30.0 : 1.0 / 8.0,
                    paused: !liveUpdatesEnabled || !isActive
                )
            ) { timeline in
                Color.clear
                    .onChange(of: timeline.date) { _, date in
                        tick(at: date)
                    }
            }
        }
        .onAppear {
            live.lastTick = .now
            tick(at: .now)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Monitor")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(OmniTheme.textPrimary)
            Spacer(minLength: 4)
            if mode.supportsEQOverlay {
                Toggle(isOn: $showEQCurve) {
                    Text("EQ")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                }
                .toggleStyle(.button)
                .controlSize(.mini)
                .help("Overlay EQ response curve")
            }
        }
    }

    private var modeChrome: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(VisualizerMode.allCases) { m in
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { mode = m }
                        } label: {
                            Text(m.rawValue)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(mode == m ? Color.black.opacity(0.82) : OmniTheme.textSecondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background {
                                    if mode == m {
                                        Capsule().fill(Color.white.opacity(0.92))
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

            if mode == .rta {
                HStack(spacing: 0) {
                    ForEach(RTABallisticsUI.allCases) { b in
                        Button {
                            rtaBallistics = b
                        } label: {
                            Text(b.rawValue)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(rtaBallistics == b ? OmniTheme.accent : OmniTheme.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Dashboard

    private var meterDashboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                channelMeter(label: "L", rms: live.smoothL, peak: live.smoothPeakL, tp: live.smoothTPL)
                channelMeter(label: "R", rms: live.smoothR, peak: live.smoothPeakR, tp: live.smoothTPR)
            }
            .frame(height: 18)

            HStack(spacing: 8) {
                compactStat(title: "Crest", value: String(format: "%.1f dB", max(mix.crestLeft, mix.crestRight)))
                grMeter
                correlationMeter
            }
            .frame(height: 28)

            HStack(spacing: 8) {
                compactStat(title: "M/S", value: String(format: "%.0f/%.0f", mix.midPercent, mix.sidePercent))
                compactStat(title: "Width", value: String(format: "%.0f%%", mix.width))
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                lufsChip("M", mix.lufsMomentary)
                lufsChip("S", mix.lufsShortTerm)
                lufsChip("I", mix.lufsIntegrated)
                lufsChip("TP", mix.truePeakMax, suffix: "dBTP")
            }
        }
    }

    private func channelMeter(label: String, rms: CGFloat, peak: CGFloat, tp: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(OmniTheme.textSecondary)
                .frame(width: 10)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.28))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [OmniTheme.accent.opacity(0.35), OmniTheme.accent.opacity(0.95)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(2, geo.size.width * rms))
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 2, height: 8)
                        .offset(x: max(0, geo.size.width * peak - 1))
                    Capsule()
                        .fill(OmniTheme.coral.opacity(0.9))
                        .frame(width: 2, height: 10)
                        .offset(x: max(0, geo.size.width * tp - 1))
                }
            }
            .frame(height: 6)
        }
    }

    private var grMeter: some View {
        let amount = CGFloat(min(1, abs(gr.instantaneousdB) / 12))
        let peak = CGFloat(min(1, abs(gr.peakHolddB) / 12))
        return HStack(spacing: 6) {
            Text("GR")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(OmniTheme.textSecondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.28))
                    Capsule()
                        .fill(OmniTheme.amber.opacity(0.85))
                        .frame(width: max(2, geo.size.width * amount))
                    Capsule()
                        .fill(Color.white.opacity(0.7))
                        .frame(width: 2, height: 8)
                        .offset(x: max(0, geo.size.width * peak - 1))
                }
            }
            .frame(height: 6)
            Text(String(format: "%.1f", gr.instantaneousdB))
                .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(OmniTheme.textSecondary)
                .frame(width: 32, alignment: .trailing)
        }
    }

    private var correlationMeter: some View {
        let c = CGFloat((mix.correlation + 1) * 0.5)
        let warn = mix.correlation < 0.3
        return HStack(spacing: 6) {
            Text("Corr")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(OmniTheme.textSecondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.28))
                    Capsule()
                        .fill(warn ? OmniTheme.coral.opacity(0.85) : OmniTheme.mint.opacity(0.8))
                        .frame(width: max(2, geo.size.width * c))
                    // Center (0) mark
                    Capsule()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 1, height: 10)
                        .offset(x: geo.size.width * 0.5)
                }
            }
            .frame(height: 6)
            Text(String(format: "%+.2f", mix.correlation))
                .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(warn ? OmniTheme.coral : OmniTheme.textSecondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private func compactStat(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(OmniTheme.textSecondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(OmniTheme.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
        }
    }

    private func lufsChip(_ title: String, _ value: Float, suffix: String = "LUFS") -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(OmniTheme.textSecondary)
            Text(String(format: "%.1f", value))
                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(OmniTheme.textPrimary)
            Text(suffix)
                .font(.system(size: 7, weight: .medium, design: .rounded))
                .foregroundStyle(OmniTheme.textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.22))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(OmniTheme.strokeSoft, lineWidth: 1)
                }
        }
    }

    // MARK: - Main surface

    private var spectrumSurface: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(
                Path(roundedRect: bounds, cornerRadius: 14, style: .continuous),
                with: .color(Color.black.opacity(0.22))
            )

            switch mode {
            case .spectrum:
                drawSpectrum(context: context, size: size)
            case .liquid:
                drawLiquid(context: context, size: size)
            case .mirror:
                drawMirror(context: context, size: size)
            case .rta:
                drawRTA(context: context, size: size)
            case .spectrogram:
                drawSpectrogram(context: context, size: size)
            case .scope:
                drawGoniometer(context: context, size: size)
            }

            if showEQCurve, mode.supportsEQOverlay {
                drawEQOverlay(context: context, size: size)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(OmniTheme.strokeSoft, lineWidth: 1)
        }
    }

    private var loudnessHistory: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(historyUsesLUFS ? "Loudness history (LUFS-S)" : "Loudness history (RMS)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(OmniTheme.textSecondary)
                Spacer()
                Button(historyUsesLUFS ? "LUFS" : "RMS") {
                    historyUsesLUFS.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(OmniTheme.accent)
            }
            Canvas { context, size in
                let hist = mix.loudnessHistory
                context.fill(
                    Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10, style: .continuous),
                    with: .color(Color.black.opacity(0.2))
                )
                guard hist.count > 1 else { return }
                let minDB: Float = historyUsesLUFS ? -50 : -60
                let maxDB: Float = historyUsesLUFS ? -5 : 0
                var path = Path()
                for (i, v) in hist.enumerated() {
                    let t = CGFloat(i) / CGFloat(hist.count - 1)
                    let x = t * size.width
                    let unit = CGFloat((max(minDB, min(maxDB, v)) - minDB) / (maxDB - minDB))
                    let y = size.height - 4 - unit * (size.height - 8)
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(
                    path,
                    with: .color(OmniTheme.accent.opacity(0.9)),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var sessionFooter: some View {
        let loudest = loudestAppName()
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Session")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(OmniTheme.textPrimary)
                Spacer()
                Button("Reset") {
                    engine.mixAnalyzer.resetSession()
                    engine.limiter.resetGRSession()
                    live.mix = engine.mixAnalyzer.snapshot()
                    live.gr = engine.limiter.snapshotGR()
                    live.dashboard.changed()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(OmniTheme.accent)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                sessionCell("Peak TP", String(format: "%.1f dBTP", mix.sessionPeakTP))
                sessionCell("Above −3 dBTP", formatDuration(mix.sessionSecondsAboveNeg3TP))
                sessionCell("Limiter hits", "\(gr.hitCount)")
                sessionCell("Loudest app", loudest)
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(OmniTheme.strokeSoft, lineWidth: 1)
                }
        }
    }

    private func sessionCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(OmniTheme.textSecondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(OmniTheme.textPrimary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Draw modes

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
            if i < peaks.count {
                let pu = CGFloat(dbToUnit(peaks[i]))
                let py = size.height - 10 - maxH * pu * 0.92
                context.fill(Path(CGRect(x: x, y: py - 1, width: w, height: 1.5)), with: .color(Color.white.opacity(0.35 + pu * 0.35)))
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
            path.addQuadCurve(to: CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2), control: prev)
        }
        if let last = pts.last { path.addLine(to: last) }
        var fill = path
        fill.addLine(to: CGPoint(x: size.width - inset, y: size.height - 8))
        fill.addLine(to: CGPoint(x: inset, y: size.height - 8))
        fill.closeSubpath()
        context.fill(
            fill,
            with: .linearGradient(
                Gradient(colors: [OmniTheme.accent.opacity(0.22), OmniTheme.accent.opacity(0.02)]),
                startPoint: CGPoint(x: size.width / 2, y: 0),
                endPoint: CGPoint(x: size.width / 2, y: size.height)
            )
        )
        context.stroke(path, with: .color(OmniTheme.accent.opacity(0.9)), style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
    }

    private func drawMirror(context: GraphicsContext, size: CGSize) {
        let count = bars.count
        guard count > 0 else { return }
        let inset: CGFloat = 12
        let midY = size.height * 0.5
        let usableW = size.width - inset * 2
        let gap: CGFloat = 2.2
        let w = max(1.8, (usableW - gap * CGFloat(count - 1)) / CGFloat(count))
        let maxHalf = size.height * 0.42
        var guide = Path()
        guide.move(to: CGPoint(x: inset, y: midY))
        guide.addLine(to: CGPoint(x: size.width - inset, y: midY))
        context.stroke(guide, with: .color(.white.opacity(0.06)), lineWidth: 1)
        for i in 0..<count {
            let unit = CGFloat(dbToUnit(bars[i]))
            let half = max(1.2, maxHalf * unit)
            let x = inset + CGFloat(i) * (w + gap)
            context.fill(
                Path(roundedRect: CGRect(x: x, y: midY - half, width: w, height: half), cornerRadius: w * 0.4, style: .continuous),
                with: .color(OmniTheme.accent.opacity(0.15 + unit * 0.55))
            )
            context.fill(
                Path(roundedRect: CGRect(x: x, y: midY, width: w, height: half), cornerRadius: w * 0.4, style: .continuous),
                with: .color(OmniTheme.mint.opacity(0.12 + unit * 0.4))
            )
        }
    }

    private func drawRTA(context: GraphicsContext, size: CGSize) {
        let count = rtaBars.count
        guard count > 0 else { return }
        let inset: CGFloat = 8
        let usableW = size.width - inset * 2
        let gap: CGFloat = 1.2
        let w = max(1.5, (usableW - gap * CGFloat(count - 1)) / CGFloat(count))
        let maxH = size.height - 18
        for i in 0..<count {
            let unit = CGFloat(dbToUnit(rtaBars[i]))
            let h = max(1.2, maxH * unit)
            let x = inset + CGFloat(i) * (w + gap)
            let rect = CGRect(x: x, y: size.height - 8 - h, width: w, height: h)
            context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(OmniTheme.accent.opacity(0.35 + unit * 0.55)))
        }
    }

    private func drawSpectrogram(context: GraphicsContext, size: CGSize) {
        let cols = spectroColumns
        guard !cols.isEmpty else { return }
        let colW = size.width / CGFloat(spectroWidth)
        let rowH = size.height / CGFloat(spectroBins)
        for (ci, col) in cols.enumerated() {
            let x = CGFloat(ci) * colW
            for (ri, db) in col.enumerated() {
                let unit = dbToUnit(db)
                let y = size.height - CGFloat(ri + 1) * rowH
                let color = spectroColor(unit)
                context.fill(Path(CGRect(x: x, y: y, width: colW + 0.5, height: rowH + 0.5)), with: .color(color))
            }
        }
    }

    private func spectroColor(_ unit: Float) -> Color {
        let u = max(0, min(1, Double(unit)))
        if u < 0.15 { return Color.black.opacity(0.15) }
        return Color(
            hue: 0.62 - u * 0.55,
            saturation: 0.75,
            brightness: 0.35 + u * 0.6,
            opacity: 0.35 + u * 0.65
        )
    }

    private func drawGoniometer(context: GraphicsContext, size: CGSize) {
        let inset: CGFloat = 16
        let side = min(size.width, size.height) - inset * 2
        let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
        let rect = CGRect(x: origin.x, y: origin.y, width: side, height: side)
        context.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(.white.opacity(0.08)), lineWidth: 1)
        // Cross + diagonal guides
        var cross = Path()
        cross.move(to: CGPoint(x: rect.midX, y: rect.minY))
        cross.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        cross.move(to: CGPoint(x: rect.minX, y: rect.midY))
        cross.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        context.stroke(cross, with: .color(.white.opacity(0.06)), lineWidth: 1)
        var diag = Path()
        diag.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        diag.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        context.stroke(diag, with: .color(OmniTheme.mint.opacity(0.15)), lineWidth: 1)

        guard gonio.count > 1 else { return }
        var path = Path()
        for (i, p) in gonio.enumerated() {
            // L = X, R = Y → classic Lissajous; map −1…1 into rect
            let x = rect.midX + CGFloat(p.x) * side * 0.45
            let y = rect.midY - CGFloat(p.y) * side * 0.45
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(
            path,
            with: .color(OmniTheme.accent.opacity(0.55)),
            style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawEQOverlay(context: GraphicsContext, size: CGSize) {
        guard eqCurve.count > 1 else { return }
        let inset: CGFloat = 10
        var path = Path()
        for (i, pt) in eqCurve.enumerated() {
            let x = inset + logX(freq: pt.frequency, width: size.width - inset * 2)
            // Map ±24 dB into vertical (center = 0 dB)
            let unit = CGFloat((max(-24, min(24, pt.magnitudedB)) + 24) / 48)
            let y = size.height - 10 - unit * (size.height - 20)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(
            path,
            with: .color(OmniTheme.mint.opacity(0.85)),
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
        )
    }

    // MARK: - Tick

    private func tick(at date: Date) {
        let dt = Float(min(0.05, max(1.0 / 120.0, date.timeIntervalSince(live.lastTick))))
        live.lastTick = date

        let mix = engine.mixAnalyzer.snapshot()
        live.mix = mix
        live.gr = engine.limiter.snapshotGR()

        let a = CGFloat(1 - exp(-Double(dt) / 0.04))
        let ap = CGFloat(1 - exp(-Double(dt) / 0.08))
        live.smoothL += (CGFloat(dbToUnit(mix.rmsLeft)) - live.smoothL) * a
        live.smoothR += (CGFloat(dbToUnit(mix.rmsRight)) - live.smoothR) * a
        live.smoothPeakL += (CGFloat(dbToUnit(mix.samplePeakHoldLeft)) - live.smoothPeakL) * ap
        live.smoothPeakR += (CGFloat(dbToUnit(mix.samplePeakHoldRight)) - live.smoothPeakR) * ap
        live.smoothTPL += (CGFloat(dbToUnit(mix.truePeakHoldLeft)) - live.smoothTPL) * ap
        live.smoothTPR += (CGFloat(dbToUnit(mix.truePeakHoldRight)) - live.smoothTPR) * ap
        live.dashboard.changed()

        switch mode {
        case .spectrum, .liquid, .mirror:
            live.bars = engine.spectrum.logBars(count: barCount, dt: dt)
            live.peaks = engine.spectrum.peakHoldBars()
        case .rta:
            live.rtaBars = engine.spectrum.rtaBars(
                ballistics: rtaBallistics.dsp,
                sampleRate: engine.sampleRate,
                dt: dt
            )
        case .spectrogram:
            appendSpectroColumn()
        case .scope:
            live.gonio = engine.mixAnalyzer.goniometerPoints()
        }

        if showEQCurve, mode.supportsEQOverlay {
            let signature = engine.equalizer.curveSignature()
            if signature != live.eqCurveSignature || live.eqCurve.isEmpty {
                live.eqCurve = engine.equalizer.magnitudeResponse(pointCount: 96)
                live.eqCurveSignature = signature
            }
        }
        live.surface.changed()
    }

    private func appendSpectroColumn() {
        let mags = engine.spectrum.magnitudeColumn()
        var col = [Float](repeating: -80, count: spectroBins)
        let usable = max(1, SpectrumAnalyzer.binCount - 1)
        for i in 0..<spectroBins {
            let t0 = Float(i) / Float(spectroBins)
            let t1 = Float(i + 1) / Float(spectroBins)
            let b0 = 1 + Int(pow(Float(usable), t0))
            let b1 = max(b0 + 1, 1 + Int(pow(Float(usable), t1)))
            var peak: Float = -80
            for b in b0..<min(b1, SpectrumAnalyzer.binCount) {
                peak = max(peak, mags[b])
            }
            col[i] = peak
        }
        live.spectroColumns.append(col)
        if live.spectroColumns.count > spectroWidth {
            live.spectroColumns.removeFirst(live.spectroColumns.count - spectroWidth)
        }
    }

    private func loudestAppName() -> String {
        let levels = tapManager.liveLevelsdB
        guard !levels.isEmpty else { return "—" }
        var bestPID: pid_t?
        var best: Float = -120
        for (pid, db) in levels {
            if db > best {
                best = db
                bestPID = pid
            }
        }
        guard let bestPID, best > -55 else { return "—" }
        return tapManager.runningAppAudioNodes.first(where: { $0.id == bestPID })?.appName ?? "—"
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%dm %02ds", m, s)
    }

    private func dbToUnit(_ db: Float) -> Float {
        let clamped = max(-72, min(0, db))
        let linear = (clamped + 72) / 72
        return pow(linear, 0.85)
    }

    private func logX(freq: Float, width: CGFloat) -> CGFloat {
        let minF: Float = 20
        let maxF: Float = 20_000
        let f = min(max(freq, minF), maxF)
        let t = log(f / minF) / log(maxF / minF)
        return CGFloat(t) * width
    }
}

// MARK: - Live state

/// Display-rate Monitor data. Never publishes itself; `dashboard` / `surface` notify only
/// the sections that draw them.
@MainActor
final class MonitorLive: ObservableObject {
    let dashboard = MonitorFeed()
    let surface = MonitorFeed()

    var bars: [Float] = Array(repeating: -80, count: 40)
    var peaks: [Float] = Array(repeating: -80, count: 40)
    var rtaBars: [Float] = Array(repeating: -80, count: SpectrumAnalyzer.thirdOctaveCenters.count)
    var mix = MixAnalyzer.Snapshot.silence
    var gr = AutoPreAmpLimiter.GRSnapshot.zero
    var gonio: [MixAnalyzer.GoniometerPoint] = []
    var spectroColumns: [[Float]] = []
    var eqCurve: [(frequency: Float, magnitudedB: Float)] = []
    var eqCurveSignature: UInt64 = 0

    var smoothL: CGFloat = 0
    var smoothR: CGFloat = 0
    var smoothPeakL: CGFloat = 0
    var smoothPeakR: CGFloat = 0
    var smoothTPL: CGFloat = 0
    var smoothTPR: CGFloat = 0
    var lastTick: Date = .now
}

@MainActor
final class MonitorFeed: ObservableObject {
    /// Needs a @Published property: without one the synthesized `objectWillChange` is
    /// recreated on every access and notifications reach no subscribers.
    @Published private(set) var revision: UInt = 0

    func changed() { revision &+= 1 }
}

/// Re-evaluates `content` whenever `feed` changes, without invalidating the parent view.
private struct LiveSection<Content: View>: View {
    @ObservedObject var feed: MonitorFeed
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
    }
}
