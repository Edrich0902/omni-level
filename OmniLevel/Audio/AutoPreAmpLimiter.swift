import Foundation
import os

/// Soft gain + transparent safety ceiling after EQ.
///
/// Pre-amp is a simple linear gain (slew-smoothed so fader moves don't click).
/// Soft clipping engages only for overshoots that slip past auto headroom —
/// normal levels pass completely unchanged.
public final class AutoPreAmpLimiter: @unchecked Sendable {
    public struct GRSnapshot: Sendable {
        /// Instantaneous gain reduction in dB (≤ 0).
        public var instantaneousdB: Float
        /// Peak-hold GR in dB (≤ 0).
        public var peakHolddB: Float
        /// Times soft-ceiling engaged this session.
        public var hitCount: UInt64

        public static let zero = GRSnapshot(instantaneousdB: 0, peakHolddB: 0, hitCount: 0)
    }

    private let lock = OSAllocatedUnfairLock()
    private var targetLinear: Float = 1.0
    private var currentLinear: Float = 1.0
    private var preAmpdB: Float = 0
    /// Per-sample approach toward target (~8 ms ramp at 48 kHz).
    private var slewPerSample: Float = 0.0026
    /// Hard transparency below this absolute level after gain.
    private let safetyStart: Float = 0.985
    private let ceiling: Float = 0.999

    private var grInstant: Float = 0
    private var grPeakHold: Float = 0
    private var grHitCount: UInt64 = 0
    private let grPeakDecay: Float = 0.992

    public init() {}

    public func setPreAmpdB(_ dB: Float) {
        lock.withLock {
            preAmpdB = dB
            targetLinear = pow(10.0, dB / 20.0)
        }
    }

    public func setSampleRate(_ rate: Double) {
        let steps = max(64, Int(rate * 0.008))
        lock.withLock {
            slewPerSample = 1.0 / Float(steps)
        }
    }

    public func currentPreAmpdB() -> Float {
        lock.withLock { preAmpdB }
    }

    public func snapshotGR() -> GRSnapshot {
        lock.withLock {
            GRSnapshot(
                instantaneousdB: grInstant,
                peakHolddB: grPeakHold,
                hitCount: grHitCount
            )
        }
    }

    public func resetGRSession() {
        lock.withLock {
            grInstant = 0
            grPeakHold = 0
            grHitCount = 0
        }
    }

    public func process(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }

        lock.lock()
        var gain = currentLinear
        let target = targetLinear
        let slew = slewPerSample
        var maxGR: Float = 0
        var hits: UInt64 = 0
        lock.unlock()

        // Fully transparent when pre-amp is off — no soft-clip coloring.
        if abs(target - 1) < 1e-6, abs(gain - 1) < 1e-5 {
            lock.lock()
            currentLinear = 1
            grInstant = 0
            grPeakHold *= grPeakDecay
            if grPeakHold > -0.05 { grPeakHold = 0 }
            lock.unlock()
            return
        }

        for i in 0..<frameCount {
            if abs(gain - target) > 1e-6 {
                let delta = target - gain
                let step = min(abs(delta), slew) * (delta >= 0 ? 1 : -1)
                gain += step
            }
            let (outL, grL) = applyGainSafelyReporting(left[i], gain: gain)
            let (outR, grR) = applyGainSafelyReporting(right[i], gain: gain)
            left[i] = outL
            right[i] = outR
            let gr = min(grL, grR)
            if gr < maxGR { maxGR = gr }
            if gr < -0.05 { hits += 1 }
        }

        lock.lock()
        currentLinear = gain
        grInstant = maxGR
        if maxGR < grPeakHold {
            grPeakHold = maxGR
        } else {
            grPeakHold *= grPeakDecay
            if grPeakHold > -0.05 { grPeakHold = 0 }
        }
        grHitCount += hits
        lock.unlock()
    }

    public func processInterleaved(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        var l = [Float](repeating: 0, count: frameCount)
        var r = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            l[i] = buffer[i * 2]
            r[i] = buffer[i * 2 + 1]
        }
        process(left: &l, right: &r, frameCount: frameCount)
        for i in 0..<frameCount {
            buffer[i * 2] = l[i]
            buffer[i * 2 + 1] = r[i]
        }
    }

    @inline(__always)
    private func softCeiling(_ x: Float) -> Float {
        let absX = abs(x)
        if absX <= safetyStart { return x }
        let sign: Float = x >= 0 ? 1 : -1
        let over = absX - safetyStart
        let room = max(ceiling - safetyStart, 0.001)
        let limited = safetyStart + room * tanh(over / room)
        return sign * min(limited, ceiling)
    }

    @inline(__always)
    private func applyGainSafelyReporting(_ x: Float, gain: Float) -> (Float, Float) {
        let driven = x * gain
        let y = softCeiling(driven)
        let absDriven = abs(driven)
        let absY = abs(y)
        let gr: Float
        if absDriven > 1e-6, absY < absDriven - 1e-7 {
            gr = 20 * log10(absY / absDriven)
        } else {
            gr = 0
        }
        return (y, gr)
    }
}
