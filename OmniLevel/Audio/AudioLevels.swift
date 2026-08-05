import Accelerate
import Foundation
import os

/// Dual-channel RMS and peak metering in dBFS.
public final class AudioLevels: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var rmsLeft: Float
        public var rmsRight: Float
        public var peakLeft: Float
        public var peakRight: Float

        public static let silence = Snapshot(rmsLeft: -60, rmsRight: -60, peakLeft: -60, peakRight: -60)
    }

    private let lock = OSAllocatedUnfairLock()
    private var current = Snapshot.silence
    private var peakHoldL: Float = -60
    private var peakHoldR: Float = -60
    private var peakHoldDecay: Float = 0.96

    public init() {}

    public func process(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }

        var sumSqL: Float = 0
        var sumSqR: Float = 0
        var peakL: Float = 0
        var peakR: Float = 0

        vDSP_rmsqv(left, 1, &sumSqL, vDSP_Length(frameCount))
        vDSP_rmsqv(right, 1, &sumSqR, vDSP_Length(frameCount))
        vDSP_maxmgv(left, 1, &peakL, vDSP_Length(frameCount))
        vDSP_maxmgv(right, 1, &peakR, vDSP_Length(frameCount))

        let rmsLdB = linearToDb(sumSqL)
        let rmsRdB = linearToDb(sumSqR)
        let peakLdB = linearToDb(peakL)
        let peakRdB = linearToDb(peakR)

        lock.withLock {
            peakHoldL = max(peakLdB, peakHoldL * peakHoldDecay)
            peakHoldR = max(peakRdB, peakHoldR * peakHoldDecay)
            current = Snapshot(
                rmsLeft: rmsLdB,
                rmsRight: rmsRdB,
                peakLeft: peakHoldL,
                peakRight: peakHoldR
            )
        }
    }

    public func snapshot() -> Snapshot {
        lock.withLock { current }
    }

    @inline(__always)
    private func linearToDb(_ linear: Float) -> Float {
        guard linear > 1e-6 else { return -60 }
        return max(-60, 20 * log10(linear))
    }
}
