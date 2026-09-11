import Accelerate
import Foundation
import os

/// Post-mix stereo analyzer for the Monitor suite.
///
/// Audio thread writes locked state (no allocations in the hot path beyond fixed buffers).
/// UI reads a single `Snapshot` at display rate.
public final class MixAnalyzer: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var rmsLeft: Float
        public var rmsRight: Float
        public var samplePeakLeft: Float
        public var samplePeakRight: Float
        public var samplePeakHoldLeft: Float
        public var samplePeakHoldRight: Float
        public var truePeakLeft: Float
        public var truePeakRight: Float
        public var truePeakHoldLeft: Float
        public var truePeakHoldRight: Float
        public var crestLeft: Float
        public var crestRight: Float
        public var correlation: Float
        public var midPercent: Float
        public var sidePercent: Float
        public var width: Float
        public var lufsMomentary: Float
        public var lufsShortTerm: Float
        public var lufsIntegrated: Float
        public var truePeakMax: Float
        public var sessionPeakTP: Float
        public var sessionSecondsAboveNeg3TP: Double
        public var loudnessHistory: [Float]

        public static let silence = Snapshot(
            rmsLeft: -60, rmsRight: -60,
            samplePeakLeft: -60, samplePeakRight: -60,
            samplePeakHoldLeft: -60, samplePeakHoldRight: -60,
            truePeakLeft: -60, truePeakRight: -60,
            truePeakHoldLeft: -60, truePeakHoldRight: -60,
            crestLeft: 0, crestRight: 0,
            correlation: 1,
            midPercent: 100, sidePercent: 0, width: 0,
            lufsMomentary: -70, lufsShortTerm: -70, lufsIntegrated: -70,
            truePeakMax: -60,
            sessionPeakTP: -60,
            sessionSecondsAboveNeg3TP: 0,
            loudnessHistory: []
        )
    }

    public struct GoniometerPoint: Sendable {
        public var x: Float
        public var y: Float
    }

    public static let goniometerCapacity = 512
    public static let historyCapacity = 120

    private let lock = OSAllocatedUnfairLock()

    // Level state
    private var rmsL: Float = -60
    private var rmsR: Float = -60
    private var samplePeakL: Float = -60
    private var samplePeakR: Float = -60
    private var sampleHoldL: Float = -60
    private var sampleHoldR: Float = -60
    private var truePeakL: Float = -60
    private var truePeakR: Float = -60
    private var trueHoldL: Float = -60
    private var trueHoldR: Float = -60
    private var correlation: Float = 1
    private var midEnergy: Float = 1
    private var sideEnergy: Float = 0

    // True-peak previous samples for 4× interpolation
    private var prevL: Float = 0
    private var prevR: Float = 0

    // Correlation accumulators (EMA)
    private var corrSumLR: Float = 0
    private var corrSumL2: Float = 0
    private var corrSumR2: Float = 0

    // Goniometer ring
    private var gonioX: [Float]
    private var gonioY: [Float]
    private var gonioWrite = 0
    private var gonioCount = 0
    private var gonioDecimate = 0

    // K-weighting + loudness
    private var sampleRate: Double = 48_000
    private var k1L = BiquadState()
    private var k1R = BiquadState()
    private var k2L = BiquadState()
    private var k2R = BiquadState()
    private var kConfiguredRate: Double = 0

    private var momentMeanSquares: [Float]
    private var momentWrite = 0
    private var momentFilled = 0
    private var shortMeanSquares: [Float]
    private var shortWrite = 0
    private var shortFilled = 0
    private var integratedBlocks: [Float] = []
    private var blockEnergyAccum: Float = 0
    private var blockSampleCount: Int = 0
    private var history: [Float]
    private var historyWrite = 0
    private var historyFilled = 0
    private var historySampleAccum: Float = 0
    private var historySampleCount: Int = 0

    private var lufsM: Float = -70
    private var lufsS: Float = -70
    private var lufsI: Float = -70

    // Session
    private var sessionPeakTP: Float = -60
    private var sessionSecondsAboveNeg3: Double = 0
    private var framesAboveNeg3: UInt64 = 0
    private var totalFrames: UInt64 = 0

    private let peakHoldDecay: Float = 0.965

    public init() {
        gonioX = [Float](repeating: 0, count: Self.goniometerCapacity)
        gonioY = [Float](repeating: 0, count: Self.goniometerCapacity)
        // ~400 ms @ 48 kHz in ~10 ms hops → 40 slots; we store mean-square per ~10 ms chunk
        momentMeanSquares = [Float](repeating: 0, count: 40)
        shortMeanSquares = [Float](repeating: 0, count: 300) // ~3 s
        history = [Float](repeating: -70, count: Self.historyCapacity)
        configureKFilters(rate: 48_000)
    }

    public func setSampleRate(_ rate: Double) {
        guard rate > 0 else { return }
        lock.withLock {
            sampleRate = rate
            if abs(rate - kConfiguredRate) > 1 {
                configureKFilters(rate: rate)
            }
        }
    }

    public func resetSession() {
        lock.withLock {
            sessionPeakTP = -60
            sessionSecondsAboveNeg3 = 0
            framesAboveNeg3 = 0
            totalFrames = 0
            integratedBlocks.removeAll(keepingCapacity: true)
            blockEnergyAccum = 0
            blockSampleCount = 0
            historyWrite = 0
            historyFilled = 0
            historySampleAccum = 0
            historySampleCount = 0
            for i in 0..<history.count { history[i] = -70 }
            lufsI = -70
            sampleHoldL = -60
            sampleHoldR = -60
            trueHoldL = -60
            trueHoldR = -60
        }
    }

    /// Audio-thread entry. `dt` implied by frameCount / sampleRate.
    public func process(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }

        var sumSqL: Float = 0
        var sumSqR: Float = 0
        var peakAbsL: Float = 0
        var peakAbsR: Float = 0
        var tpAbsL: Float = 0
        var tpAbsR: Float = 0
        var sumLR: Float = 0
        var sumL2: Float = 0
        var sumR2: Float = 0
        var midE: Float = 0
        var sideE: Float = 0
        var kWeightedEnergy: Float = 0

        lock.lock()
        let rate = sampleRate
        var pL = prevL
        var pR = prevR
        var gWrite = gonioWrite
        var gCount = gonioCount
        var gDec = gonioDecimate
        var bAccum = blockEnergyAccum
        var bCount = blockSampleCount
        var hAccum = historySampleAccum
        var hCount = historySampleCount
        lock.unlock()

        // Ensure K filters match rate (rare path).
        if abs(rate - kConfiguredRate) > 1 {
            lock.lock()
            configureKFilters(rate: rate)
            lock.unlock()
        }

        for i in 0..<frameCount {
            let l = left[i]
            let r = right[i]
            let al = abs(l)
            let ar = abs(r)
            peakAbsL = max(peakAbsL, al)
            peakAbsR = max(peakAbsR, ar)

            // 4× true-peak via cubic-ish samples between prev and current
            tpAbsL = max(tpAbsL, al, truePeakBetween(pL, l))
            tpAbsR = max(tpAbsR, ar, truePeakBetween(pR, r))
            pL = l
            pR = r

            sumSqL += l * l
            sumSqR += r * r
            sumLR += l * r
            sumL2 += l * l
            sumR2 += r * r

            let mid = 0.5 * (l + r)
            let side = 0.5 * (l - r)
            midE += mid * mid
            sideE += side * side

            // K-weight both channels, average energy
            let kl = k2L.process(k1L.process(l))
            let kr = k2R.process(k1R.process(r))
            kWeightedEnergy += 0.5 * (kl * kl + kr * kr)

            // Goniometer: decimate
            gDec += 1
            if gDec >= 4 {
                gDec = 0
                gonioX[gWrite] = max(-1, min(1, l))
                gonioY[gWrite] = max(-1, min(1, r))
                gWrite += 1
                if gWrite >= Self.goniometerCapacity { gWrite = 0 }
                if gCount < Self.goniometerCapacity { gCount += 1 }
            }
        }

        let invN = 1 / Float(frameCount)
        let rmsLinL = sqrt(sumSqL * invN)
        let rmsLinR = sqrt(sumSqR * invN)
        let rmsDbL = linearToDb(rmsLinL)
        let rmsDbR = linearToDb(rmsLinR)
        let spL = linearToDb(peakAbsL)
        let spR = linearToDb(peakAbsR)
        let tpL = linearToDb(tpAbsL)
        let tpR = linearToDb(tpAbsR)
        let tpMax = max(tpL, tpR)

        // Correlation for this block → EMA
        let denom = sqrt(max(sumL2 * sumR2, 1e-20))
        let blockCorr = denom > 0 ? max(-1, min(1, sumLR / denom)) : 1

        let meanSq = kWeightedEnergy * invN
        bAccum += kWeightedEnergy
        bCount += frameCount
        hAccum += meanSq
        hCount += 1

        // ~400 ms momentary window via ~10 ms chunks
        let chunkSamples = max(1, Int(rate * 0.01))
        let blockSamples = max(1, Int(rate * 0.4)) // gating block for integrated

        lock.lock()
        prevL = pL
        prevR = pR
        gonioWrite = gWrite
        gonioCount = gCount
        gonioDecimate = gDec

        rmsL = rmsDbL
        rmsR = rmsDbR
        samplePeakL = spL
        samplePeakR = spR
        sampleHoldL = max(spL, sampleHoldL * peakHoldDecay)
        sampleHoldR = max(spR, sampleHoldR * peakHoldDecay)
        truePeakL = tpL
        truePeakR = tpR
        trueHoldL = max(tpL, trueHoldL * peakHoldDecay)
        trueHoldR = max(tpR, trueHoldR * peakHoldDecay)

        corrSumLR = corrSumLR * 0.85 + sumLR * 0.15
        corrSumL2 = corrSumL2 * 0.85 + sumL2 * 0.15
        corrSumR2 = corrSumR2 * 0.85 + sumR2 * 0.15
        let cDen = sqrt(max(corrSumL2 * corrSumR2, 1e-20))
        correlation = cDen > 0 ? max(-1, min(1, corrSumLR / cDen)) : blockCorr

        midEnergy = midEnergy * 0.9 + midE * 0.1
        sideEnergy = sideEnergy * 0.9 + sideE * 0.1

        // Momentary / short-term mean-square rings
        pushMeanSquare(meanSq, into: &momentMeanSquares, write: &momentWrite, filled: &momentFilled)
        pushMeanSquare(meanSq, into: &shortMeanSquares, write: &shortWrite, filled: &shortFilled)

        let momMS = averageRing(momentMeanSquares, filled: momentFilled)
        let shortMS = averageRing(shortMeanSquares, filled: shortFilled)
        lufsM = meanSquareToLUFS(momMS)
        lufsS = meanSquareToLUFS(shortMS)

        blockEnergyAccum = bAccum
        blockSampleCount = bCount
        if bCount >= blockSamples {
            let blockMS = bAccum / Float(bCount)
            integratedBlocks.append(blockMS)
            if integratedBlocks.count > 2_000 {
                integratedBlocks.removeFirst(integratedBlocks.count - 2_000)
            }
            blockEnergyAccum = 0
            blockSampleCount = 0
            lufsI = gatedIntegratedLUFS(integratedBlocks)
        }

        // History ~1 Hz from short-term
        historySampleAccum = hAccum
        historySampleCount = hCount
        let historyHop = max(1, Int(rate / Double(max(frameCount, 1)))) // ~1 sec of callbacks
        // Use time: accumulate frames
        totalFrames += UInt64(frameCount)
        if tpMax > sessionPeakTP { sessionPeakTP = tpMax }
        if tpMax >= -3 {
            framesAboveNeg3 += UInt64(frameCount)
        }
        sessionSecondsAboveNeg3 = Double(framesAboveNeg3) / rate

        // Push history every ~1 s of audio
        let framesPerHistory = UInt64(max(1, rate))
        if totalFrames > 0, totalFrames % framesPerHistory < UInt64(frameCount) {
            let value = lufsS
            history[historyWrite] = value
            historyWrite = (historyWrite + 1) % Self.historyCapacity
            if historyFilled < Self.historyCapacity { historyFilled += 1 }
            historySampleAccum = 0
            historySampleCount = 0
        }

        // Silence unused warning
        _ = chunkSamples
        _ = historyHop

        lock.unlock()
    }

    public func snapshot() -> Snapshot {
        lock.withLock {
            let mid = midEnergy
            let side = sideEnergy
            let total = max(mid + side, 1e-20)
            let midPct = mid / total * 100
            let sidePct = side / total * 100
            let width = min(100, sidePct * 2) // 0 = mono, ~100 = wide
            let crestL = max(0, trueHoldL - rmsL)
            let crestR = max(0, trueHoldR - rmsR)
            let hist = orderedHistory()
            return Snapshot(
                rmsLeft: rmsL,
                rmsRight: rmsR,
                samplePeakLeft: samplePeakL,
                samplePeakRight: samplePeakR,
                samplePeakHoldLeft: sampleHoldL,
                samplePeakHoldRight: sampleHoldR,
                truePeakLeft: truePeakL,
                truePeakRight: truePeakR,
                truePeakHoldLeft: trueHoldL,
                truePeakHoldRight: trueHoldR,
                crestLeft: crestL,
                crestRight: crestR,
                correlation: correlation,
                midPercent: midPct,
                sidePercent: sidePct,
                width: width,
                lufsMomentary: lufsM,
                lufsShortTerm: lufsS,
                lufsIntegrated: lufsI,
                truePeakMax: max(trueHoldL, trueHoldR),
                sessionPeakTP: sessionPeakTP,
                sessionSecondsAboveNeg3TP: sessionSecondsAboveNeg3,
                loudnessHistory: hist
            )
        }
    }

    /// Copy goniometer points newest-last for Canvas.
    public func goniometerPoints() -> [GoniometerPoint] {
        lock.withLock {
            let count = gonioCount
            guard count > 0 else { return [] }
            var out: [GoniometerPoint] = []
            out.reserveCapacity(count)
            let start = (gonioWrite - count + Self.goniometerCapacity) % Self.goniometerCapacity
            for i in 0..<count {
                let idx = (start + i) % Self.goniometerCapacity
                out.append(GoniometerPoint(x: gonioX[idx], y: gonioY[idx]))
            }
            return out
        }
    }

    // MARK: - Helpers

    private func orderedHistory() -> [Float] {
        guard historyFilled > 0 else { return [] }
        var out = [Float](repeating: -70, count: historyFilled)
        let start = (historyWrite - historyFilled + Self.historyCapacity) % Self.historyCapacity
        for i in 0..<historyFilled {
            out[i] = history[(start + i) % Self.historyCapacity]
        }
        return out
    }

    private func pushMeanSquare(
        _ value: Float,
        into ring: inout [Float],
        write: inout Int,
        filled: inout Int
    ) {
        ring[write] = value
        write = (write + 1) % ring.count
        if filled < ring.count { filled += 1 }
    }

    private func averageRing(_ ring: [Float], filled: Int) -> Float {
        guard filled > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<filled { sum += ring[i] }
        // When not full, only first `filled` are valid from start — actually ring wraps.
        // Simpler: average entire filled portion by scanning write-backwards.
        if filled < ring.count {
            return sum / Float(filled)
        }
        sum = 0
        for v in ring { sum += v }
        return sum / Float(ring.count)
    }

    private func meanSquareToLUFS(_ ms: Float) -> Float {
        guard ms > 1e-12 else { return -70 }
        return max(-70, 10 * log10(ms) - 0.691)
    }

    /// Absolute gate −70 LUFS, relative gate −10 LU from ungated loudness (simplified R128).
    private func gatedIntegratedLUFS(_ blocks: [Float]) -> Float {
        guard !blocks.isEmpty else { return -70 }
        let absoluteThresh = pow(10 as Float, (-70.0 + 0.691) / 10.0)
        let aboveAbs = blocks.filter { $0 > absoluteThresh }
        guard !aboveAbs.isEmpty else { return -70 }
        let ungated = aboveAbs.reduce(0, +) / Float(aboveAbs.count)
        let ungatedLUFS = meanSquareToLUFS(ungated)
        let relativeThresh = pow(10 as Float, (ungatedLUFS - 10 + 0.691) / 10.0)
        let gated = aboveAbs.filter { $0 > relativeThresh }
        guard !gated.isEmpty else { return ungatedLUFS }
        let gatedMS = gated.reduce(0, +) / Float(gated.count)
        return meanSquareToLUFS(gatedMS)
    }

    @inline(__always)
    private func truePeakBetween(_ a: Float, _ b: Float) -> Float {
        // Evaluate at 1/4, 1/2, 3/4 with hermite-ish linear+cubic blend
        var peak: Float = 0
        for t in [Float(0.25), 0.5, 0.75] {
            // Catmull-Rom-ish with duplicated endpoints: lerp + slight overshoot via smoothstep
            let x = a + (b - a) * t
            // Add parabolic peak estimate
            let mid = (a + b) * 0.5
            let curve = mid + (mid - (a * (1 - t) + b * t)) * 0.15
            peak = max(peak, abs(x), abs(curve))
        }
        return peak
    }

    @inline(__always)
    private func linearToDb(_ linear: Float) -> Float {
        guard linear > 1e-6 else { return -60 }
        return max(-60, 20 * log10(linear))
    }

    // MARK: - BS.1770-ish K-weight filters

    private struct BiquadState {
        var z1: Float = 0
        var z2: Float = 0
        var b0: Float = 1, b1: Float = 0, b2: Float = 0
        var a1: Float = 0, a2: Float = 0

        mutating func set(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
            self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
            z1 = 0; z2 = 0
        }

        @inline(__always)
        mutating func process(_ x: Float) -> Float {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private func configureKFilters(rate: Double) {
        kConfiguredRate = rate
        // Stage 1: high shelf +4 dB @ ~1.5 kHz (pre-filter)
        setHighShelf(&k1L, rate: rate, freq: 1500, gainDb: 4)
        setHighShelf(&k1R, rate: rate, freq: 1500, gainDb: 4)
        // Stage 2: highpass ~38 Hz
        setHighPass(&k2L, rate: rate, freq: 38)
        setHighPass(&k2R, rate: rate, freq: 38)
    }

    private func setHighShelf(_ s: inout BiquadState, rate: Double, freq: Double, gainDb: Double) {
        let a = pow(10.0, gainDb / 40.0)
        let w0 = 2 * Double.pi * freq / rate
        let cosw = cos(w0)
        let sinw = sin(w0)
        let alpha = sinw / 2 * sqrt(2)
        let b0 = a * ((a + 1) + (a - 1) * cosw + 2 * sqrt(a) * alpha)
        let b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
        let b2 = a * ((a + 1) + (a - 1) * cosw - 2 * sqrt(a) * alpha)
        let a0 = (a + 1) - (a - 1) * cosw + 2 * sqrt(a) * alpha
        let a1 = 2 * ((a - 1) - (a + 1) * cosw)
        let a2 = (a + 1) - (a - 1) * cosw - 2 * sqrt(a) * alpha
        s.set(
            b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
            a1: Float(a1 / a0), a2: Float(a2 / a0)
        )
    }

    private func setHighPass(_ s: inout BiquadState, rate: Double, freq: Double) {
        let w0 = 2 * Double.pi * freq / rate
        let cosw = cos(w0)
        let sinw = sin(w0)
        let alpha = sinw / 2 * sqrt(2)
        let b0 = (1 + cosw) / 2
        let b1 = -(1 + cosw)
        let b2 = (1 + cosw) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosw
        let a2 = 1 - alpha
        s.set(
            b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
            a1: Float(a1 / a0), a2: Float(a2 / a0)
        )
    }
}
