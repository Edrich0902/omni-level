import Accelerate
import Foundation
import os

/// Lightweight realtime FFT + display smoothing for the Monitor tab.
///
/// - Audio thread only writes a small ring (no allocations / no FFT).
/// - UI thread runs FFT at display rate (~60 Hz) into preallocated buffers.
/// - Display bars use dual attack/release so motion feels fluid without churn.
public final class SpectrumAnalyzer: @unchecked Sendable {
    public static let fftSize = 1024 // Smaller than 2048: still musical, half the work
    public static let binCount = fftSize / 2

    private let lock = OSAllocatedUnfairLock()
    private let fftSetup: vDSP.FFT<DSPSplitComplex>
    private var window: [Float]
    private var timeDomain: [Float]
    private var splitReal: [Float]
    private var splitImag: [Float]
    private var magnitudes: [Float]
    private var ring: [Float]
    private var writeIndex = 0

    /// Display-domain smoothed log bars (UI thread only).
    private var displayBars: [Float] = []
    private var peakBars: [Float] = []

    public init() {
        let log2n = vDSP_Length(10) // 2^10 = 1024
        self.fftSetup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
        self.window = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        self.timeDomain = [Float](repeating: 0, count: Self.fftSize)
        self.splitReal = [Float](repeating: 0, count: Self.binCount)
        self.splitImag = [Float](repeating: 0, count: Self.binCount)
        self.magnitudes = [Float](repeating: -80, count: Self.binCount)
        self.ring = [Float](repeating: 0, count: Self.fftSize)
    }

    /// Audio-thread write. Compact loop, no FFT.
    public func push(samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        // Decimate if very dense by writing every other sample once ring is busy —
        // keep full write for fidelity; 512 frames is fine.
        var i = 0
        while i < count {
            ring[writeIndex] = samples[i]
            writeIndex += 1
            if writeIndex >= Self.fftSize { writeIndex = 0 }
            i += 1
        }
        lock.unlock()
    }

    /// Full FFT into magnitudes (dB). Call from UI/display thread only.
    @discardableResult
    public func analyze() -> [Float] {
        lock.lock()
        let start = writeIndex
        for i in 0..<Self.fftSize {
            timeDomain[i] = ring[(start + i) % Self.fftSize]
        }
        lock.unlock()

        vDSP_vmul(timeDomain, 1, window, 1, &timeDomain, 1, vDSP_Length(Self.fftSize))

        timeDomain.withUnsafeBufferPointer { td in
            splitReal.withUnsafeMutableBufferPointer { re in
                splitImag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    td.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.binCount) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(Self.binCount))
                    }
                    fftSetup.forward(input: split, output: &split)
                }
            }
        }

        let scale = Float(1.0 / Float(Self.fftSize))
        for i in 0..<Self.binCount {
            let re = splitReal[i]
            let im = splitImag[i]
            let mag = sqrt(re * re + im * im) * scale
            magnitudes[i] = mag > 1e-9 ? max(-80, 20 * log10(mag)) : -80
        }
        return magnitudes
    }

    /// Log-spaced bars with asymmetric attack/release for silky motion.
    /// - Parameters:
    ///   - count: number of display bars
    ///   - dt: seconds since last frame (for frame-rate independent smoothing)
    public func logBars(count: Int = 48, dt: Float = 1.0 / 60.0) -> [Float] {
        _ = analyze()
        guard count > 0 else { return [] }

        if displayBars.count != count {
            displayBars = [Float](repeating: -80, count: count)
            peakBars = [Float](repeating: -80, count: count)
        }

        let usableBins = Self.binCount
        let minBin = 1
        let maxBin = usableBins - 1

        // Frame-rate independent smoothing factors.
        let attack = 1 - exp(-dt / 0.018)   // ~18 ms rise
        let release = 1 - exp(-dt / 0.12)   // ~120 ms fall
        let peakRelease = 1 - exp(-dt / 0.55)

        for i in 0..<count {
            let t0 = Float(i) / Float(count)
            let t1 = Float(i + 1) / Float(count)
            // Log spacing via exponent on bin range
            let b0 = minBin + Int(pow(Float(maxBin - minBin), t0))
            let b1 = max(b0 + 1, minBin + Int(pow(Float(maxBin - minBin), t1)))
            var peak: Float = -80
            let end = min(b1, usableBins)
            var b = b0
            while b < end {
                peak = max(peak, magnitudes[b])
                b += 1
            }

            let prev = displayBars[i]
            let alpha = peak > prev ? attack : release
            let smoothed = prev + (peak - prev) * alpha
            displayBars[i] = smoothed

            if peak > peakBars[i] {
                peakBars[i] = peak
            } else {
                peakBars[i] += (smoothed - peakBars[i]) * peakRelease
            }
        }
        return displayBars
    }

    /// Soft peak-hold trail companion for the current bar set.
    public func peakHoldBars() -> [Float] {
        peakBars
    }

    // MARK: - EQ fader band energies

    private var bandDisplay: [Float] = []
    private var bandPeaks: [Float] = []

    /// Energy (dBFS, smoothed) around each centre frequency — call after/instead of
    /// `logBars` on the display thread. Uses the most recent FFT in `magnitudes`.
    public func levelsNearFrequencies(
        _ frequencies: [Float],
        sampleRate: Double,
        dt: Float = 1.0 / 60.0
    ) -> [Float] {
        _ = analyze()
        let count = frequencies.count
        guard count > 0, sampleRate > 0 else { return [] }

        if bandDisplay.count != count {
            bandDisplay = [Float](repeating: -80, count: count)
            bandPeaks = [Float](repeating: -80, count: count)
        }

        let attack = 1 - exp(-dt / 0.02)
        let release = 1 - exp(-dt / 0.14)
        let nyquist = Float(sampleRate) * 0.5
        let binHz = Float(sampleRate) / Float(Self.fftSize)

        for (i, freq) in frequencies.enumerated() {
            let f = min(max(freq, 20), nyquist * 0.98)
            // Bin neighbourhood ~⅓ octave so sparse bands still light up.
            let halfWidth = max(binHz * 1.5, f * 0.12)
            let lo = max(1, Int((f - halfWidth) / binHz))
            let hi = min(Self.binCount - 1, Int((f + halfWidth) / binHz) + 1)

            var peak: Float = -80
            var b = lo
            while b <= hi {
                peak = max(peak, magnitudes[b])
                b += 1
            }

            let prev = bandDisplay[i]
            let alpha = peak > prev ? attack : release
            bandDisplay[i] = prev + (peak - prev) * alpha
        }
        return bandDisplay
    }

    // MARK: - 1/3-octave RTA

    public enum RTABallistics: Sendable {
        case fast
        case slow
        case peakHold
    }

    /// ISO-ish 1/3-octave centre frequencies (25 Hz … 20 kHz).
    public static let thirdOctaveCenters: [Float] = [
        25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315,
        400, 500, 630, 800, 1_000, 1_250, 1_600, 2_000, 2_500, 3_150,
        4_000, 5_000, 6_300, 8_000, 10_000, 12_500, 16_000, 20_000
    ]

    private var rtaDisplay: [Float] = []
    private var rtaPeaks: [Float] = []

    /// Calibrated 1/3-octave RTA bars (dBFS). Call from UI/display thread.
    public func rtaBars(
        ballistics: RTABallistics = .fast,
        sampleRate: Double,
        dt: Float = 1.0 / 60.0
    ) -> [Float] {
        _ = analyze()
        let freqs = Self.thirdOctaveCenters
        let count = freqs.count
        guard count > 0, sampleRate > 0 else { return [] }

        if rtaDisplay.count != count {
            rtaDisplay = [Float](repeating: -80, count: count)
            rtaPeaks = [Float](repeating: -80, count: count)
        }

        let attack: Float
        let release: Float
        switch ballistics {
        case .fast:
            attack = 1 - exp(-dt / 0.015)
            release = 1 - exp(-dt / 0.09)
        case .slow:
            attack = 1 - exp(-dt / 0.04)
            release = 1 - exp(-dt / 0.35)
        case .peakHold:
            attack = 1 - exp(-dt / 0.012)
            release = 1 - exp(-dt / 1.2)
        }

        let nyquist = Float(sampleRate) * 0.5
        let binHz = Float(sampleRate) / Float(Self.fftSize)

        for (i, freq) in freqs.enumerated() {
            let f = min(max(freq, 20), nyquist * 0.98)
            // ±1/6 octave ≈ one 1/3-octave band
            let halfWidth = max(binHz * 1.2, f * (pow(2, 1.0 / 6.0) - 1))
            let lo = max(1, Int((f - halfWidth) / binHz))
            let hi = min(Self.binCount - 1, Int((f + halfWidth) / binHz) + 1)

            var peak: Float = -80
            var b = lo
            while b <= hi {
                peak = max(peak, magnitudes[b])
                b += 1
            }

            let prev = rtaDisplay[i]
            let alpha = peak > prev ? attack : release
            let smoothed = prev + (peak - prev) * alpha
            rtaDisplay[i] = smoothed

            if peak > rtaPeaks[i] {
                rtaPeaks[i] = peak
            } else if ballistics == .peakHold {
                rtaPeaks[i] += (smoothed - rtaPeaks[i]) * (1 - exp(-dt / 1.4))
            } else {
                rtaPeaks[i] = smoothed
            }
        }
        return ballistics == .peakHold ? rtaPeaks : rtaDisplay
    }

    public func rtaPeakHoldBars() -> [Float] {
        rtaPeaks
    }

    /// Latest FFT magnitudes in dB (UI thread). Useful for spectrogram columns.
    public func magnitudeColumn() -> [Float] {
        _ = analyze()
        return magnitudes
    }
}
