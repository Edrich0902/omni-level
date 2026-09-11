import Foundation
import os

/// Soft gain + transparent safety ceiling after EQ.
///
/// Pre-amp is a simple linear gain (slew-smoothed so fader moves don't click).
/// Soft clipping engages only for overshoots that slip past auto headroom —
/// normal levels pass completely unchanged.
public final class AutoPreAmpLimiter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var targetLinear: Float = 1.0
    private var currentLinear: Float = 1.0
    private var preAmpdB: Float = 0
    /// Per-sample approach toward target (~8 ms ramp at 48 kHz).
    private var slewPerSample: Float = 0.0026
    /// Hard transparency below this absolute level after gain.
    private let safetyStart: Float = 0.985
    private let ceiling: Float = 0.999

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
        lock.unlock()

        // Fully transparent when pre-amp is off — no soft-clip coloring.
        if abs(target - 1) < 1e-6, abs(gain - 1) < 1e-5 {
            lock.lock()
            currentLinear = 1
            lock.unlock()
            return
        }

        for i in 0..<frameCount {
            if abs(gain - target) > 1e-6 {
                let delta = target - gain
                let step = min(abs(delta), slew) * (delta >= 0 ? 1 : -1)
                gain += step
            }
            left[i] = applyGainSafely(left[i], gain: gain)
            right[i] = applyGainSafely(right[i], gain: gain)
        }

        lock.lock()
        currentLinear = gain
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
    private func applyGainSafely(_ x: Float, gain: Float) -> Float {
        softCeiling(x * gain)
    }
}
