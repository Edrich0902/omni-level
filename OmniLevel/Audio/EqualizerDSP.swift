import Foundation
import os

/// Realtime-safe 16-band peaking EQ.
///
/// Parameter updates **never** tear down filters or clear filter memory — that was
/// the source of zipper/static while dragging. Coefficients are double-buffered and
/// swapped atomically; biquad delay state stays continuous across edits.
public final class EqualizerDSP: @unchecked Sendable {
    public static let bandCount = EqualizerBand.standardFrequencies.count

    private let lock = OSAllocatedUnfairLock()
    private var sampleRate: Double = 48_000
    private var bands: [EqualizerBand]
    private var autoPreAmpEnabled: Bool = true
    private var autoPreAmpdB: Float = 0
    private var isWireBypass: Bool = true

    /// Double-buffered RBJ coeffs: band-major groups of 5 (b0,b1,b2,a1,a2) as Float.
    private var coeffFront: [Float]
    private var coeffBack: [Float]
    private var usingFront: Bool = true

    /// Transposed direct-form II state — one (z1,z2) per section per channel.
    private var zL1: [Float]
    private var zL2: [Float]
    private var zR1: [Float]
    private var zR2: [Float]

    public init() {
        self.bands = EqualizerBand.standardBands()
        let n = Self.bandCount
        self.coeffFront = [Float](repeating: 0, count: n * 5)
        self.coeffBack = [Float](repeating: 0, count: n * 5)
        self.zL1 = [Float](repeating: 0, count: n)
        self.zL2 = [Float](repeating: 0, count: n)
        self.zR1 = [Float](repeating: 0, count: n)
        self.zR2 = [Float](repeating: 0, count: n)
        rebuildFilters(resetState: true)
        recalculateAutoPreAmp()
        isWireBypass = true
    }

    // MARK: - State accessors

    public func snapshotBands() -> [EqualizerBand] {
        lock.withLock { bands }
    }

    public func currentAutoPreAmpdB() -> Float {
        lock.withLock { autoPreAmpdB }
    }

    public func isAutoPreAmpEnabled() -> Bool {
        lock.withLock { autoPreAmpEnabled }
    }

    public func setSampleRate(_ rate: Double) {
        lock.withLock {
            guard rate > 0, abs(rate - sampleRate) > 0.5 else { return }
            sampleRate = rate
            // Rate change requires fresh memory; sample-rate jumps are rare.
            rebuildFilters(resetState: true)
        }
    }

    public func setAutoPreAmpEnabled(_ enabled: Bool) {
        lock.withLock {
            autoPreAmpEnabled = enabled
            recalculateAutoPreAmp()
        }
    }

    public func updateBandGain(at index: Int, gaindB: Float) {
        lock.withLock {
            guard bands.indices.contains(index) else { return }
            bands[index].gaindB = max(EqualizerBand.gainRange.lowerBound,
                                      min(EqualizerBand.gainRange.upperBound, gaindB))
            recalculateAutoPreAmp()
            rebuildFilters(resetState: false)
        }
    }

    public func updateBandQ(at index: Int, q: Float) {
        lock.withLock {
            guard bands.indices.contains(index) else { return }
            bands[index].qFactor = max(0.1, min(10, q))
            rebuildFilters(resetState: false)
        }
    }

    public func applyGains(_ gains: [Float], qFactors: [Float]? = nil) {
        lock.withLock {
            for i in 0..<min(bands.count, gains.count) {
                bands[i].gaindB = max(EqualizerBand.gainRange.lowerBound,
                                      min(EqualizerBand.gainRange.upperBound, gains[i]))
                if let qFactors, i < qFactors.count {
                    bands[i].qFactor = max(0.1, min(10, qFactors[i]))
                }
            }
            recalculateAutoPreAmp()
            // Preset jumps can be large; brief reset avoids DC buildup from extreme prior state.
            rebuildFilters(resetState: true)
        }
    }

    public func resetFlat() {
        applyGains(Array(repeating: 0, count: Self.bandCount))
    }

    // MARK: - Processing (audio thread)

    public func processInterleavedStereo(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            left[i] = buffer[i * 2]
            right[i] = buffer[i * 2 + 1]
        }
        processChannels(left: &left, right: &right, frameCount: frameCount)
        for i in 0..<frameCount {
            buffer[i * 2] = left[i]
            buffer[i * 2 + 1] = right[i]
        }
    }

    public func processChannels(left: inout [Float], right: inout [Float], frameCount: Int) {
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                processChannels(
                    left: lBuf.baseAddress!,
                    right: rBuf.baseAddress!,
                    frameCount: frameCount
                )
            }
        }
    }

    /// Realtime path — only holds the lock for a snapshot; processing stays off the lock
    /// so fader drags (coeff rebuild) do not stall the mix thread for an entire buffer.
    public func processChannels(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }

        lock.lock()
        let bypass = isWireBypass
        let useFront = usingFront
        lock.unlock()
        if bypass { return }

        // Coeff arrays are double-buffered; inactive side is written only under lock.
        // Active side is stable for the duration of a buffer.
        let coeffs = useFront ? coeffFront : coeffBack
        let n = Self.bandCount

        for i in 0..<frameCount {
            var xL = left[i]
            var xR = right[i]
            for s in 0..<n {
                let c = s * 5
                let b0 = coeffs[c], b1 = coeffs[c + 1], b2 = coeffs[c + 2]
                let a1 = coeffs[c + 3], a2 = coeffs[c + 4]

                // Transposed DF-II — continuous state across parameter edits.
                let yL = b0 * xL + zL1[s]
                zL1[s] = b1 * xL - a1 * yL + zL2[s]
                zL2[s] = b2 * xL - a2 * yL
                xL = yL

                let yR = b0 * xR + zR1[s]
                zR1[s] = b1 * xR - a1 * yR + zR2[s]
                zR2[s] = b2 * xR - a2 * yR
                xR = yR
            }
            left[i] = xL
            right[i] = xR
        }
    }

    // MARK: - Frequency response for UI curve

    /// Fingerprint for caching magnitude curves in the UI.
    public func curveSignature() -> UInt64 {
        lock.withLock {
            var h: UInt64 = 1_469_598_103_934_665_603
            for b in bands {
                h = h &* 1_099_511_628_211 &+ UInt64(b.gaindB.bitPattern)
                h = h &* 1_099_511_628_211 &+ UInt64(b.qFactor.bitPattern)
            }
            h = h &* 1_099_511_628_211 &+ UInt64(sampleRate.bitPattern)
            return h
        }
    }

    public func magnitudeResponse(pointCount: Int = 128) -> [(frequency: Float, magnitudedB: Float)] {
        let snapshot: (bands: [EqualizerBand], sr: Float) = lock.withLock {
            (bands, Float(sampleRate))
        }
        let sr = snapshot.sr
        let nyquist = sr * 0.5
        var points: [(Float, Float)] = []
        points.reserveCapacity(pointCount)

        let fMin: Float = 20
        let fMax = min(nyquist * 0.98, 20_000)
        for i in 0..<pointCount {
            let t = Float(i) / Float(max(pointCount - 1, 1))
            let freq = fMin * pow(fMax / fMin, t)
            var mag: Float = 0
            for band in snapshot.bands {
                mag += peakingMagnitudedB(
                    frequency: freq,
                    center: band.frequency,
                    gaindB: band.gaindB,
                    q: band.qFactor,
                    sampleRate: sr
                )
            }
            points.append((freq, mag))
        }
        return points
    }

    // MARK: - Internals

    private func recalculateAutoPreAmp() {
        guard autoPreAmpEnabled else {
            autoPreAmpdB = 0
            return
        }
        let peakBoost = bands.map(\.gaindB).max() ?? 0
        if peakBoost > 0 {
            autoPreAmpdB = -peakBoost - 1.0
        } else {
            autoPreAmpdB = 0
        }
    }

    /// Rebuild coefficient table into the inactive buffer, then flip — never zeros filters while dragging.
    private func rebuildFilters(resetState: Bool) {
        let n = Self.bandCount
        var anyBoost = false
        // Write into the inactive half so the audio thread can keep reading the front.
        let writeToFront = !usingFront
        var target = writeToFront ? coeffFront : coeffBack

        for (i, band) in bands.enumerated() {
            if abs(band.gaindB) > 0.02 { anyBoost = true }
            let c = peakingCoefficients(
                frequency: Double(band.frequency),
                gaindB: Double(band.gaindB),
                q: Double(band.qFactor),
                sampleRate: sampleRate
            )
            let base = i * 5
            target[base] = Float(c.b0)
            target[base + 1] = Float(c.b1)
            target[base + 2] = Float(c.b2)
            target[base + 3] = Float(c.a1)
            target[base + 4] = Float(c.a2)
        }

        if writeToFront {
            coeffFront = target
        } else {
            coeffBack = target
        }
        usingFront = writeToFront
        isWireBypass = !anyBoost

        if resetState {
            for i in 0..<n {
                zL1[i] = 0; zL2[i] = 0
                zR1[i] = 0; zR2[i] = 0
            }
        }
    }

    /// RBJ peaking EQ, a0-normalized.
    private func peakingCoefficients(
        frequency: Double,
        gaindB: Double,
        q: Double,
        sampleRate: Double
    ) -> (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        let A = pow(10.0, gaindB / 40.0)
        let w0 = 2.0 * Double.pi * min(frequency, sampleRate * 0.49) / sampleRate
        let alpha = sin(w0) / (2.0 * max(q, 0.05))
        let cosw0 = cos(w0)

        let b0 = 1 + alpha * A
        let b1 = -2 * cosw0
        let b2 = 1 - alpha * A
        let a0 = 1 + alpha / A
        let a1 = -2 * cosw0
        let a2 = 1 - alpha / A

        return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }

    private func peakingMagnitudedB(
        frequency: Float,
        center: Float,
        gaindB: Float,
        q: Float,
        sampleRate: Float
    ) -> Float {
        let A = pow(10.0, gaindB / 40.0)
        let w0 = 2.0 * Float.pi * min(center, sampleRate * 0.49) / sampleRate
        let w = 2.0 * Float.pi * frequency / sampleRate
        let alpha = sin(w0) / (2.0 * max(q, 0.05))
        let cosw0 = cos(w0)
        let cosw = cos(w)

        let b0 = 1 + alpha * A
        let b1: Float = -2 * cosw0
        let b2 = 1 - alpha * A
        let a0 = 1 + alpha / A
        let a1: Float = -2 * cosw0
        let a2 = 1 - alpha / A

        let zb0 = b0 / a0, zb1 = b1 / a0, zb2 = b2 / a0
        let za1 = a1 / a0, za2 = a2 / a0

        let numRe = zb0 + zb1 * cosw + zb2 * cos(2 * w)
        let numIm = -zb1 * sin(w) - zb2 * sin(2 * w)
        let denRe = 1 + za1 * cosw + za2 * cos(2 * w)
        let denIm = -za1 * sin(w) - za2 * sin(2 * w)

        let numMag = sqrt(numRe * numRe + numIm * numIm)
        let denMag = max(sqrt(denRe * denRe + denIm * denIm), 1e-12)
        let ratio = numMag / denMag
        return 20 * log10(max(ratio, 1e-12))
    }
}
