import Foundation

/// Lightweight offline DSP validation exercises (no XCTest host required to compile into app).
/// Call `DSPValidation.runAll()` from a debug console or unit test target.
public enum DSPValidation {
    public struct Report: Sendable {
        public var name: String
        public var passed: Bool
        public var detail: String
    }

    @discardableResult
    public static func runAll() -> [Report] {
        [
            testAutoPreAmpOffset(),
            testEQAmplifiesAtBandCenter(),
            testLimiterBoundsOutput(),
            testAutoEQMapping(),
            testGainPanMute()
        ]
    }

    public static func testAutoPreAmpOffset() -> Report {
        let dsp = EqualizerDSP()
        dsp.setAutoPreAmpEnabled(true)
        dsp.updateBandGain(at: 0, gaindB: 6)
        let offset = dsp.currentAutoPreAmpdB()
        // Response peak ≈ band gain near Fc + 2.5 dB headroom (negative offset).
        let ok = offset < -6.0 && offset > -12.0
        return Report(
            name: "Auto Pre-Amp",
            passed: ok,
            detail: "expected less than -6 dB for +6 band, got \(offset)"
        )
    }

    public static func testEQAmplifiesAtBandCenter() -> Report {
        let dsp = EqualizerDSP()
        dsp.setSampleRate(48_000)
        dsp.setAutoPreAmpEnabled(false)
        dsp.updateBandGain(at: 8, gaindB: 12) // 1 kHz band

        let frames = 2048
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        let freq: Float = 1000
        let sr: Float = 48_000
        for i in 0..<frames {
            let s = sin(2 * Float.pi * freq * Float(i) / sr) * 0.25
            left[i] = s
            right[i] = s
        }

        // Measure input peak
        let inPeak = left.map { abs($0) }.max() ?? 0
        dsp.processChannels(left: &left, right: &right, frameCount: frames)
        // Skip transient settling
        let outPeak = left[512...].map { abs($0) }.max() ?? 0
        let ratio = outPeak / max(inPeak, 1e-6)
        // At +12 dB peaking center we expect meaningful boost (allow tolerance for Q slope)
        let ok = ratio > 1.5
        return Report(
            name: "EQ boost at 1 kHz",
            passed: ok,
            detail: String(format: "peak ratio %.2f (want > 1.5)", ratio)
        )
    }

    public static func testLimiterBoundsOutput() -> Report {
        let limiter = AutoPreAmpLimiter()
        limiter.setPreAmpdB(12) // +12 dB boost into limiter
        let frames = 512
        var left = [Float](repeating: 0.8, count: frames)
        var right = [Float](repeating: -0.8, count: frames)
        limiter.process(left: &left, right: &right, frameCount: frames)
        let maxAbs = max(left.map { abs($0) }.max() ?? 0, right.map { abs($0) }.max() ?? 0)
        let ok = maxAbs <= 1.0001
        return Report(
            name: "Limiter ceiling",
            passed: ok,
            detail: String(format: "max abs %.4f", maxAbs)
        )
    }

    public static func testAutoEQMapping() -> Report {
        let text = """
        Preamp: -5.5 dB
        PK,100,3.0,1.2
        PK,1000,-2.0,0.7
        PK,8000,1.5,1.0
        """
        let profile = AutoEQImporter.parse(text: text, name: "Test")
        let mapped = AutoEQImporter.mapToSixteenBands(profile)
        let ok = mapped.gains.count == 16 && profile.filters.count == 3 && profile.preAmpdB != nil
        return Report(
            name: "AutoEQ import map",
            passed: ok,
            detail: "filters=\(profile.filters.count) preamp=\(String(describing: profile.preAmpdB))"
        )
    }

    public static func testGainPanMute() -> Report {
        let mixer = GainPanMixer()
        mixer.setStream(1, params: .init(volume: 1, pan: 0, isMuted: true, isSolo: false))
        let g = mixer.effectiveGains(for: 1)
        let muteOK = g.left == 0 && g.right == 0

        mixer.setStream(1, params: .init(volume: 1, pan: -1, isMuted: false, isSolo: false))
        let left = mixer.effectiveGains(for: 1)
        let panOK = left.left > 0.9 && left.right < 0.1

        mixer.setStream(1, params: .init(volume: 1, pan: 0, isMuted: false, isSolo: false))
        mixer.setStream(2, params: .init(volume: 1, pan: 0, isMuted: false, isSolo: true))
        let soloGate = mixer.effectiveGains(for: 1)
        let soloOK = soloGate.left == 0 && soloGate.right == 0

        return Report(
            name: "Gain/Pan/Mute/Solo",
            passed: muteOK && panOK && soloOK,
            detail: "mute=\(muteOK) pan=\(panOK) solo=\(soloOK)"
        )
    }
}
