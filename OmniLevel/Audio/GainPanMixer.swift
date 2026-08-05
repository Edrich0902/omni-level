import Accelerate
import Foundation
import os

/// Per-stream gain / stereo balance with mute and solo semantics.
public final class GainPanMixer: @unchecked Sendable {
    public struct StreamParams: Sendable {
        public var volume: Float
        public var pan: Float
        public var isMuted: Bool
        public var isSolo: Bool

        public init(volume: Float = 1, pan: Float = 0, isMuted: Bool = false, isSolo: Bool = false) {
            self.volume = volume
            self.pan = pan
            self.isMuted = isMuted
            self.isSolo = isSolo
        }

        /// Stereo **balance** law (not mono constant-power pan).
        public var channelGains: (Float, Float) {
            guard !isMuted && volume > 0 else { return (0, 0) }
            let v = max(0, volume)
            let p = max(-1, min(1, pan))
            if p <= 0 {
                return (v, v * (1 + p))
            } else {
                return (v * (1 - p), v)
            }
        }
    }

    private let lock = OSAllocatedUnfairLock()
    private var streams: [pid_t: StreamParams] = [:]
    /// Cached so the mix path never scans every stream for solo each buffer.
    private var anySolo: Bool = false

    public init() {}

    public func setStream(_ pid: pid_t, params: StreamParams) {
        lock.withLock {
            streams[pid] = params
            anySolo = streams.values.contains(where: \.isSolo)
        }
    }

    public func removeStream(_ pid: pid_t) {
        lock.withLock {
            _ = streams.removeValue(forKey: pid)
            anySolo = streams.values.contains(where: \.isSolo)
        }
    }

    public func clear() {
        lock.withLock {
            streams.removeAll()
            anySolo = false
        }
    }

    public func effectiveGains(for pid: pid_t) -> (left: Float, right: Float) {
        lock.withLock {
            guard let params = streams[pid] else {
                return (1, 1)
            }
            if anySolo && !params.isSolo {
                return (0, 0)
            }
            return params.channelGains
        }
    }

    public func applyStereo(
        pid: pid_t,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        let (gL, gR) = effectiveGains(for: pid)
        if abs(gL - 1) < 1e-6, abs(gR - 1) < 1e-6 { return }
        if gL == 0, gR == 0 {
            memset(left, 0, frameCount * MemoryLayout<Float>.size)
            memset(right, 0, frameCount * MemoryLayout<Float>.size)
            return
        }
        var gl = gL
        var gr = gR
        vDSP_vsmul(left, 1, &gl, left, 1, vDSP_Length(frameCount))
        vDSP_vsmul(right, 1, &gr, right, 1, vDSP_Length(frameCount))
    }

    public func mix(
        pid: pid_t,
        sourceLeft: UnsafePointer<Float>,
        sourceRight: UnsafePointer<Float>?,
        destLeft: UnsafeMutablePointer<Float>,
        destRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        let (gL, gR) = effectiveGains(for: pid)
        if gL == 0 && gR == 0 { return }
        let n = vDSP_Length(frameCount)

        if let sourceRight {
            if abs(gL - 1) < 1e-6, abs(gR - 1) < 1e-6 {
                vDSP_vadd(destLeft, 1, sourceLeft, 1, destLeft, 1, n)
                vDSP_vadd(destRight, 1, sourceRight, 1, destRight, 1, n)
            } else {
                var gl = gL
                var gr = gR
                vDSP_vsma(sourceLeft, 1, &gl, destLeft, 1, destLeft, 1, n)
                vDSP_vsma(sourceRight, 1, &gr, destRight, 1, destRight, 1, n)
            }
        } else {
            var gl = gL
            var gr = gR
            vDSP_vsma(sourceLeft, 1, &gl, destLeft, 1, destLeft, 1, n)
            vDSP_vsma(sourceLeft, 1, &gr, destRight, 1, destRight, 1, n)
        }
    }
}
