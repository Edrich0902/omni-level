import Foundation
import os

/// Auto pre-amp + soft brickwall with **slew-limited gain** so EQ-driven pre-amp
/// changes never zipper while dragging bands.
public final class AutoPreAmpLimiter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var targetLinear: Float = 1.0
    private var currentLinear: Float = 1.0
    private var preAmpdB: Float = 0
    /// Per-sample approach toward target (~5 ms ramp at 48 kHz).
    private var slewPerSample: Float = 0.004
    private var ceiling: Float = 0.99
    private var softKnee: Float = 0.05

    public init() {}

    public func setPreAmpdB(_ dB: Float) {
        lock.withLock {
            preAmpdB = dB
            targetLinear = pow(10.0, dB / 20.0)
        }
    }

    public func setSampleRate(_ rate: Double) {
        // Reach target in ~8 ms regardless of rate.
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

        // Fully transparent when both sit at unity.
        if abs(target - 1) < 1e-6, abs(gain - 1) < 1e-5 {
            currentLinear = 1
            return
        }

        for i in 0..<frameCount {
            if abs(gain - target) > 1e-6 {
                let delta = target - gain
                let step = min(abs(delta), slew) * (delta >= 0 ? 1 : -1)
                gain += step
            }
            let g = gain
            left[i] = softLimit(left[i] * g, ceiling: 0.999, knee: 0.01)
            right[i] = softLimit(right[i] * g, ceiling: 0.999, knee: 0.01)
        }

        lock.lock()
        currentLinear = gain
        lock.unlock()
    }

    public func processInterleaved(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        // De-interleave path for tools; rare.
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
    private func softLimit(_ x: Float, ceiling: Float, knee: Float) -> Float {
        let absX = abs(x)
        if absX < ceiling - knee {
            return x
        }
        let sign: Float = x >= 0 ? 1 : -1
        let over = absX - (ceiling - knee)
        let t = tanh(over / max(knee, 0.001))
        let limited = (ceiling - knee) + t * knee
        return max(-1.0, min(1.0, sign * min(limited, ceiling)))
    }
}
