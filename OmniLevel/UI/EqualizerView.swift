import SwiftUI
import UniformTypeIdentifiers

struct EqualizerView: View {
    @ObservedObject var viewModel: EqualizerViewModel
    @ObservedObject var presetStore: PresetStore
    /// Used for live per-band input/output spectrum on the faders.
    var engine: AudioEngineController
    /// Number of apps with a stored per-app EQ override.
    var overrideAppCount: Int = 0
    /// Optional title override (e.g. per-app editor).
    var title: String = "Equalizer"
    var subtitleOverride: String? = nil
    /// Hide AutoEQ library / import when editing a per-app override.
    var showsLibraryControls: Bool = true
    /// When set, fader meters use these analyzers instead of the global mix bus.
    var meterSpectrumInput: SpectrumAnalyzer? = nil
    var meterSpectrum: SpectrumAnalyzer? = nil

    @State private var showImporter = false
    @State private var showAutoEQLibrary = false
    @StateObject private var autoEQLibrary = AutoEQLibraryService()
    @State private var importError: String?
    @State private var showSaveSheet = false
    @State private var newPresetName = ""
    /// Live meter data. Not observed here — only the meter / underlay leaf views observe it,
    /// so meter ticks never rebuild the header, curve, sliders or controls.
    @StateObject private var live = EQLiveMeters()

    private let sliderHeight: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            curveCanvas
                .frame(height: 110)
            bandSliders
            controlsRow
        }
        .padding(16)
        .glassCard(cornerRadius: 20)
        .background {
            EQMeterTicker(
                live: live,
                input: meterSpectrumInput ?? engine.spectrumInput,
                output: meterSpectrum ?? engine.spectrum,
                engine: engine
            )
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText, .utf8PlainText],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .sheet(isPresented: $showAutoEQLibrary) {
            AutoEQLibrarySheet(
                library: autoEQLibrary,
                onApply: { profile in
                    viewModel.applyAutoEQ(profile)
                },
                onImportFile: {
                    showImporter = true
                }
            )
        }
        .alert("Import Failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("Save Preset", isPresented: $showSaveSheet) {
            TextField("Preset name", text: $newPresetName)
            Button("Cancel", role: .cancel) {
                newPresetName = ""
            }
            Button("Save") {
                saveCurrentPreset()
            }
        } message: {
            Text("Save the current 16-band curve as a custom preset.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(OmniTheme.textPrimary)
                Text(headerSubtitle)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(OmniTheme.textSecondary)
            }
            Spacer()
            Text(viewModel.autoPreAmpEnabled
                 ? String(format: "Pre‑Amp  %.1f dB", viewModel.autoPreAmpdB)
                 : "Pre‑Amp  Off")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(viewModel.autoPreAmpEnabled ? OmniTheme.accent : OmniTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    (viewModel.autoPreAmpEnabled ? OmniTheme.accent : OmniTheme.textSecondary).opacity(0.14),
                    in: Capsule()
                )
                .overlay {
                    Capsule().strokeBorder(
                        (viewModel.autoPreAmpEnabled ? OmniTheme.accent : OmniTheme.textSecondary).opacity(0.28),
                        lineWidth: 1
                    )
                }
        }
    }

    private var headerSubtitle: String {
        if let subtitleOverride { return subtitleOverride }
        if overrideAppCount > 0 {
            let n = overrideAppCount
            return "Global — overridden by \(n) app\(n == 1 ? "" : "s")"
        }
        return "Band meters · blue = in · amber = out · mint = your gain"
    }

    private var curveCanvas: some View {
        ZStack {
            // Live spectrum underlay (pre ghost + post fill) on the same log-frequency axis.
            EQSpectrumUnderlay(feed: live.spectrum)
            curveShape
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.25))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(OmniTheme.strokeSoft, lineWidth: 1)
                }
        }
    }

    /// Gridlines, target, response curve and band nodes; redraws only when the EQ changes.
    private var curveShape: some View {
        let points = viewModel.magnitudePoints(count: 120)
        return Canvas { context, size in
            // Faint gridlines
            for db in stride(from: -24, through: 24, by: 12) {
                let y = yPosition(db: Float(db), height: size.height)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.white.opacity(db == 0 ? 0.18 : 0.06)), lineWidth: 1)
            }

            if let target = viewModel.targetCurveGains {
                let targetPath = bandPolyline(gains: target, size: size)
                context.stroke(targetPath, with: .color(OmniTheme.mint.opacity(0.28)), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
            }

            let path = smoothPath(points: points, size: size)
            var fill = path
            if let lastX = points.last.map({ xPosition(freq: $0.frequency, width: size.width) }) {
                fill.addLine(to: CGPoint(x: lastX, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                context.fill(
                    fill,
                    with: .linearGradient(
                        Gradient(colors: [OmniTheme.accent.opacity(0.28), OmniTheme.mint.opacity(0.02)]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )
            }
            context.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: [OmniTheme.accent, OmniTheme.mint]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            )

            // Band nodes
            for band in viewModel.bands {
                let x = xPosition(freq: band.frequency, width: size.width)
                let y = yPosition(db: band.gaindB, height: size.height)
                let r: CGFloat = 3.5
                let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.9)))
                context.stroke(Path(ellipseIn: rect), with: .color(OmniTheme.accent.opacity(0.8)), lineWidth: 1)
            }
        }
    }

    private var bandSliders: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(viewModel.bands.enumerated()), id: \.element.id) { index, band in
                VStack(spacing: 6) {
                    Text(String(format: "%+.0f", band.gaindB))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(abs(band.gaindB) < 0.5 ? OmniTheme.textSecondary : OmniTheme.accent)
                        .frame(height: 12)
                        .monospacedDigit()
                        .contentTransition(.numericText())

                    VerticalGainSlider(
                        value: Binding(
                            get: { Double(band.gaindB) },
                            set: { viewModel.updateGain(at: index, value: Float($0)) }
                        ),
                        range: Double(EqualizerBand.gainRange.lowerBound)...Double(EqualizerBand.gainRange.upperBound),
                        trackHeight: sliderHeight
                    ) {
                        EQBandMeter(feed: live.bands, index: index)
                    }
                    .frame(maxWidth: .infinity)

                    Text(band.frequencyLabel)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(OmniTheme.textSecondary)
                        .frame(height: 12)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: sliderHeight + 40)
        .padding(.vertical, 4)
    }

    private var controlsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(presetStore.presets) { preset in
                        Button(preset.name) {
                            viewModel.applyPreset(preset)
                        }
                    }
                    if presetStore.presets.contains(where: { !$0.isBuiltIn }) {
                        Divider()
                        ForEach(presetStore.presets.filter { !$0.isBuiltIn }) { preset in
                            Button("Delete “\(preset.name)”", role: .destructive) {
                                presetStore.deleteUserPreset(id: preset.id)
                                if viewModel.selectedPresetName == preset.name {
                                    viewModel.applyPreset(EQPreset.builtIn[0])
                                }
                            }
                        }
                    }
                } label: {
                    GlassChip(title: viewModel.selectedPresetName, systemImage: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)

                Button {
                    showSaveSheet = true
                } label: {
                    GlassChip(title: "Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .help("Save current EQ as a custom preset")

                if showsLibraryControls {
                    Button {
                        showAutoEQLibrary = true
                    } label: {
                        GlassChip(title: "AutoEQ", systemImage: "headphones")
                    }
                    .buttonStyle(.plain)
                    .help("Browse the AutoEq library or import a ParametricEQ file")
                }
                Button {
                    viewModel.applyPreset(EQPreset.builtIn[0])
                } label: {
                    GlassChip(title: "Flat", systemImage: "minus")
                }
                .buttonStyle(.plain)
                .help("Reset all bands to 0 dB")
            }

            Toggle(isOn: Binding(
                get: { viewModel.autoPreAmpEnabled },
                set: { viewModel.setAutoPreAmpEnabled($0) }
            )) {
                Text("Auto Pre‑Amp")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(OmniTheme.textPrimary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(OmniTheme.accent)
        }
    }

    // MARK: - Paths

    private func smoothPath(points: [(frequency: Float, magnitudedB: Float)], size: CGSize) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        let mapped = points.map {
            CGPoint(x: xPosition(freq: $0.frequency, width: size.width),
                    y: yPosition(db: $0.magnitudedB, height: size.height))
        }
        path.move(to: mapped[0])
        for i in 1..<mapped.count {
            let prev = mapped[i - 1]
            let curr = mapped[i]
            let mid = CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2)
            path.addQuadCurve(to: mid, control: prev)
        }
        if let last = mapped.last {
            path.addLine(to: last)
        }
        return path
    }

    private func bandPolyline(gains: [Float], size: CGSize) -> Path {
        var path = Path()
        let freqs = EqualizerBand.standardFrequencies
        for (i, g) in gains.enumerated() where i < freqs.count {
            let p = CGPoint(
                x: xPosition(freq: freqs[i], width: size.width),
                y: yPosition(db: g, height: size.height)
            )
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private func xPosition(freq: Float, width: CGFloat) -> CGFloat {
        eqCurveX(freq: freq, width: width)
    }

    private func yPosition(db: Float, height: CGFloat) -> CGFloat {
        let clamped = max(-24, min(24, db))
        let t = (clamped + 24) / 48
        return height * (1 - CGFloat(t))
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let profile = try AutoEQImporter.importFile(at: url)
                viewModel.applyAutoEQ(profile)
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func saveCurrentPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let gains = viewModel.bands.map(\.gaindB)
        let qs = viewModel.bands.map(\.qFactor)
        presetStore.saveUserPreset(name: name, gainsdB: gains, qFactors: qs)
        if let preset = presetStore.presets.last(where: { $0.name == name && !$0.isBuiltIn }) {
            viewModel.applyPreset(preset)
        }
        newPresetName = ""
    }
}

/// Log-frequency x position (20 Hz … 20 kHz) shared by the curve and its spectrum underlay.
private func eqCurveX(freq: Float, width: CGFloat) -> CGFloat {
    let fMin: Float = 20
    let fMax: Float = 20_000
    let t = log(max(freq, fMin) / fMin) / log(fMax / fMin)
    return CGFloat(t) * width
}

// MARK: - Live meters

/// Owns the EQ pane's live data. Never publishes; the meter and underlay views read it on
/// their own `LiveTimeline` ticks, so the rest of the pane isn't rebuilt.
@MainActor
final class EQLiveMeters: ObservableObject {
    let bands = EQBandMeterFeed()
    let spectrum = EQSpectrumFeed()
    private var lastTick: Date = .now
    private static let underlayBarCount = 48

    /// One FFT per analyzer per tick: band levels run `analyze()`, the underlay reuses it.
    func tick(at date: Date, input: SpectrumAnalyzer, output: SpectrumAnalyzer, sampleRate: Double) {
        let dt = Float(min(0.12, max(1.0 / 60.0, date.timeIntervalSince(lastTick))))
        lastTick = date
        let freqs = EqualizerBand.standardFrequencies
        let rawIn = input.levelsNearFrequencies(freqs, sampleRate: sampleRate, dt: dt)
        let rawOut = output.levelsNearFrequencies(freqs, sampleRate: sampleRate, dt: dt)
        bands.update(
            input: rawIn.map { CGFloat(Self.dbToUnit($0)) },
            output: rawOut.map { CGFloat(Self.dbToUnit($0)) }
        )
        spectrum.update(
            pre: Self.logBins(input.latestMagnitudes()),
            post: Self.logBins(output.latestMagnitudes())
        )
    }

    private static func logBins(_ mags: [Float]) -> [Float] {
        let count = underlayBarCount
        guard !mags.isEmpty else { return Array(repeating: -80, count: count) }
        var out = [Float](repeating: -80, count: count)
        let usable = max(1, SpectrumAnalyzer.binCount - 1)
        for i in 0..<count {
            let t0 = Float(i) / Float(count)
            let t1 = Float(i + 1) / Float(count)
            let b0 = 1 + Int(pow(Float(usable), t0))
            let b1 = max(b0 + 1, 1 + Int(pow(Float(usable), t1)))
            var peak: Float = -80
            for b in b0..<min(b1, mags.count) {
                peak = max(peak, mags[b])
            }
            out[i] = peak
        }
        return out
    }

    private static func dbToUnit(_ db: Float) -> Float {
        let clamped = max(-70, min(0, db))
        return pow((clamped + 70) / 70, 0.82)
    }
}

@MainActor
final class EQBandMeterFeed {
    struct Levels {
        var input = [CGFloat](repeating: 0, count: EqualizerDSP.bandCount)
        var output = [CGFloat](repeating: 0, count: EqualizerDSP.bandCount)
    }

    private(set) var levels = Levels()

    func update(input: [CGFloat], output: [CGFloat]) {
        levels = Levels(input: input, output: output)
    }
}

@MainActor
final class EQSpectrumFeed {
    struct Bins {
        var pre = [Float](repeating: -80, count: 48)
        var post = [Float](repeating: -80, count: 48)
    }

    private(set) var bins = Bins()

    func update(pre: [Float], post: [Float]) {
        bins = Bins(pre: pre, post: post)
    }
}

/// Drives `EQLiveMeters` at display rate while the EQ pane is on screen in an open popover.
private struct EQMeterTicker: View {
    let live: EQLiveMeters
    let input: SpectrumAnalyzer
    let output: SpectrumAnalyzer
    let engine: AudioEngineController
    @Environment(\.liveUpdatesEnabled) private var liveUpdatesEnabled

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !liveUpdatesEnabled)) { timeline in
            Color.clear
                .onChange(of: timeline.date) { _, date in
                    live.tick(at: date, input: input, output: output, sampleRate: engine.sampleRate)
                }
        }
        .onAppear {
            live.tick(at: .now, input: input, output: output, sampleRate: engine.sampleRate)
        }
    }
}

private struct EQBandMeter: View {
    let feed: EQBandMeterFeed
    let index: Int

    var body: some View {
        LiveTimeline {
            let levels = feed.levels
            GainSliderMeterBars(
                inputLevel: index < levels.input.count ? levels.input[index] : 0,
                outputLevel: index < levels.output.count ? levels.output[index] : 0
            )
        }
    }
}

private struct EQSpectrumUnderlay: View {
    let feed: EQSpectrumFeed

    var body: some View {
        LiveTimeline {
            let bins = feed.bins
            Canvas { context, size in
                Self.draw(context: context, size: size, values: bins.pre, color: OmniTheme.accent.opacity(0.12))
                Self.draw(context: context, size: size, values: bins.post, color: OmniTheme.amber.opacity(0.22))
            }
            .allowsHitTesting(false)
        }
    }

    private static func draw(context: GraphicsContext, size: CGSize, values: [Float], color: Color) {
        guard values.count > 1 else { return }
        let count = values.count
        var path = Path()
        for i in 0..<count {
            let t = Float(i) / Float(count - 1)
            let freq = 20 * pow(1000, t) // 20…20k log
            let x = eqCurveX(freq: freq, width: size.width)
            // Map −72…0 dBFS into lower 55% of canvas height (under the ±24 dB curve)
            let unit = max(0, min(1, (values[i] + 72) / 72))
            let y = size.height - CGFloat(unit) * size.height * 0.55
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }
}
