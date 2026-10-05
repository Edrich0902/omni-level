import Foundation
import os

/// Realtime-safe 16-band peaking EQ.
///
/// Parameter updates **never** tear down filters or clear filter memory — that was
/// the source of zipper/static while dragging. Biquad delay state stays continuous
/// across edits.
///
/// Threading: control methods publish coefficients into `pending` under `lock`.
/// The audio thread only ever *tries* the lock to pick up a new generation, so a
/// UI thread holding it can never stall a render cycle. Filter memory lives in a
/// `RenderState` owned by exactly one audio thread (one per output bus for the
/// shared global EQ).
public final class EqualizerDSP: @unchecked Sendable {
    public static let bandCount = EqualizerBand.standardFrequencies.count
    static let coeffStride = 5

    /// Per-render-thread filter memory + private copy of the active coefficients.
    final class RenderState: @unchecked Sendable {
        fileprivate let coeffs: UnsafeMutablePointer<Float>
        /// Per section: zL1, zL2, zR1, zR2.
        fileprivate let z: UnsafeMutablePointer<Float>
        fileprivate var generation: UInt64 = .max
        fileprivate var resetGeneration: UInt64 = 0
        fileprivate var bypass = true

        init() {
            let n = EqualizerDSP.bandCount
            coeffs = .allocate(capacity: n * EqualizerDSP.coeffStride)
            coeffs.initialize(repeating: 0, count: n * EqualizerDSP.coeffStride)
            z = .allocate(capacity: n * 4)
            z.initialize(repeating: 0, count: n * 4)
        }

        deinit {
            coeffs.deallocate()
            z.deallocate()
        }
    }

    private let lock = OSAllocatedUnfairLock()
    private var sampleRate: Double = 48_000
    private var bands: [EqualizerBand]
    private var autoPreAmpEnabled: Bool = false
    private var autoPreAmpdB: Float = 0

    /// Latest RBJ coeffs: band-major groups of 5 (b0,b1,b2,a1,a2). Written under `lock`.
    private let pending: UnsafeMutablePointer<Float>
    private var pendingBypass = true
    private var pendingGeneration: UInt64 = 0
    private var pendingResetGeneration: UInt64 = 0

    /// State used by the single-bus `processChannels` overloads (override EQs, tests).
    private let defaultState = RenderState()

    public init() {
        self.bands = EqualizerBand.standardBands()
        let n = Self.bandCount
        self.pending = .allocate(capacity: n * Self.coeffStride)
        pending.initialize(repeating: 0, count: n * Self.coeffStride)
        rebuildFilters(resetState: true)
        recalculateAutoPreAmp()
    }

    deinit {
        pending.deallocate()
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

    /// Realtime path using this EQ's own filter memory. Only one thread may call this.
    public func processChannels(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        processChannels(left: left, right: right, frameCount: frameCount, state: defaultState)
    }

    /// Realtime path with caller-owned filter memory (one `RenderState` per audio thread).
    /// Never blocks and never allocates.
    func processChannels(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int,
        state: RenderState
    ) {
        guard frameCount > 0 else { return }
        syncCoefficients(into: state)
        if state.bypass { return }

        let coeffs = state.coeffs
        let z = state.z
        for s in 0..<Self.bandCount {
            let c = coeffs + s * Self.coeffStride
            let b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[3], a2 = c[4]
            let zs = z + s * 4

            // Transposed DF-II, one section across the whole block per channel.
            var z1 = zs[0], z2 = zs[1]
            for i in 0..<frameCount {
                let x = left[i]
                let y = b0 * x + z1
                z1 = b1 * x - a1 * y + z2
                z2 = b2 * x - a2 * y
                left[i] = y
            }
            zs[0] = Self.flushDenormal(z1)
            zs[1] = Self.flushDenormal(z2)

            z1 = zs[2]; z2 = zs[3]
            for i in 0..<frameCount {
                let x = right[i]
                let y = b0 * x + z1
                z1 = b1 * x - a1 * y + z2
                z2 = b2 * x - a2 * y
                right[i] = y
            }
            zs[2] = Self.flushDenormal(z1)
            zs[3] = Self.flushDenormal(z2)
        }
    }

    /// Picks up the latest published coefficients if the lock is free; otherwise keeps
    /// the previous set for one more buffer.
    private func syncCoefficients(into state: RenderState) {
        guard lock.lockIfAvailable() else { return }
        if state.generation != pendingGeneration {
            state.coeffs.update(from: pending, count: Self.bandCount * Self.coeffStride)
            state.bypass = pendingBypass
            state.generation = pendingGeneration
        }
        let resetGen = pendingResetGeneration
        lock.unlock()

        if state.resetGeneration != resetGen {
            state.z.update(repeating: 0, count: Self.bandCount * 4)
            state.resetGeneration = resetGen
        }
    }

    @inline(__always)
    private static func flushDenormal(_ v: Float) -> Float {
        abs(v) < 1e-20 ? 0 : v
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
        // True cascade peak (Σ peaking dB) — using only max band under-cuts when
        // neighboring boosts stack, so the post-EQ soft limit crushed the music.
        let peakBoost = responsePeakBoostdB(samples: 96)
        if peakBoost > 0.15 {
            // Extra 2.5 dB of headroom keeps the safety clipper out of regular peaks.
            autoPreAmpdB = -peakBoost - 2.5
        } else {
            autoPreAmpdB = 0
        }
    }

    /// Peak magnitude boost of the current curve (must be called with lock held).
    private func responsePeakBoostdB(samples: Int) -> Float {
        let sr = Float(sampleRate)
        let nyquist = sr * 0.5
        let fMin: Float = 20
        let fMax = min(nyquist * 0.98, 20_000)
        var peak: Float = 0
        let n = max(samples, 16)
        for i in 0..<n {
            let t = Float(i) / Float(n - 1)
            let freq = fMin * pow(fMax / fMin, t)
            var mag: Float = 0
            for band in bands {
                mag += peakingMagnitudedB(
                    frequency: freq,
                    center: band.frequency,
                    gaindB: band.gaindB,
                    q: band.qFactor,
                    sampleRate: sr
                )
            }
            if mag > peak { peak = mag }
        }
        return peak
    }

    /// Publish a new coefficient generation (must be called with lock held) — never zeros
    /// filters while dragging; render states pick it up on their next buffer.
    private func rebuildFilters(resetState: Bool) {
        var anyBoost = false
        for (i, band) in bands.enumerated() {
            if abs(band.gaindB) > 0.02 { anyBoost = true }
            let c = peakingCoefficients(
                frequency: Double(band.frequency),
                gaindB: Double(band.gaindB),
                q: Double(band.qFactor),
                sampleRate: sampleRate
            )
            let base = i * Self.coeffStride
            pending[base] = Float(c.b0)
            pending[base + 1] = Float(c.b1)
            pending[base + 2] = Float(c.b2)
            pending[base + 3] = Float(c.a1)
            pending[base + 4] = Float(c.a2)
        }
        pendingBypass = !anyBoost
        pendingGeneration &+= 1
        if resetState { pendingResetGeneration &+= 1 }
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
