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
    @State private var inputLevels: [CGFloat] = Array(repeating: 0, count: EqualizerDSP.bandCount)
    @State private var outputLevels: [CGFloat] = Array(repeating: 0, count: EqualizerDSP.bandCount)
    @State private var lastTick: Date = .now

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
            // ~18 Hz is plenty for fader meters; less FFT + @State thrash.
            TimelineView(.animation(minimumInterval: 1.0 / 18.0, paused: false)) { timeline in
                Color.clear
                    .onChange(of: timeline.date) { _, date in
                        tickSpectrum(at: date)
                    }
            }
        }
        .onAppear { tickSpectrum(at: .now) }
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
                        trackHeight: sliderHeight,
                        inputLevel: index < inputLevels.count ? inputLevels[index] : 0,
                        outputLevel: index < outputLevels.count ? outputLevels[index] : 0
                    )
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

    /// Sample pre/post EQ energy at each band centre for the fader meters.
    private func tickSpectrum(at date: Date) {
        let dt = Float(min(0.12, max(1.0 / 30.0, date.timeIntervalSince(lastTick))))
        lastTick = date
        let freqs = EqualizerBand.standardFrequencies
        let rate = engine.sampleRate
        let inputAnalyzer = meterSpectrumInput ?? engine.spectrumInput
        let outputAnalyzer = meterSpectrum ?? engine.spectrum
        let rawIn = inputAnalyzer.levelsNearFrequencies(freqs, sampleRate: rate, dt: dt)
        let rawOut = outputAnalyzer.levelsNearFrequencies(freqs, sampleRate: rate, dt: dt)
        // Only publish @State when meters moved enough (avoids full 16-slider body).
        let nextIn = rawIn.map { CGFloat(dbToUnit($0)) }
        let nextOut = rawOut.map { CGFloat(dbToUnit($0)) }
        if levelsDiffer(inputLevels, nextIn) { inputLevels = nextIn }
        if levelsDiffer(outputLevels, nextOut) { outputLevels = nextOut }
    }

    private func levelsDiffer(_ a: [CGFloat], _ b: [CGFloat]) -> Bool {
        guard a.count == b.count else { return true }
        for i in a.indices where abs(a[i] - b[i]) > 0.012 {
            return true
        }
        return false
    }

    private func dbToUnit(_ db: Float) -> Float {
        let clamped = max(-70, min(0, db))
        return pow((clamped + 70) / 70, 0.82)
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
        let fMin: Float = 20
        let fMax: Float = 20_000
        let t = log(max(freq, fMin) / fMin) / log(fMax / fMin)
        return CGFloat(t) * width
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
