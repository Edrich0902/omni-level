import Foundation
import os

/// Keeps every meter, spectrum and loudness computation off the render thread.
///
/// The output render callback only copies audio into these rings with `tryWrite`
/// (never blocks, drops a block if the consumer happens to hold the lock). A timer on
/// a background queue drains them and runs the analyzers, so analysis cost and UI
/// lock contention can never make the render thread miss its deadline.
final class AnalysisPump: @unchecked Sendable {
    /// Primary bus, post-limiter stereo mix.
    let postMix = StereoRingBuffer(capacityFrames: AnalysisPump.ringFrames)
    /// Primary bus global-EQ input (mono in both channels).
    let preEQ = StereoRingBuffer(capacityFrames: AnalysisPump.ringFrames)
    /// Focused app before / after its EQ (mono in both channels).
    let focusPre = StereoRingBuffer(capacityFrames: AnalysisPump.ringFrames)
    let focusPost = StereoRingBuffer(capacityFrames: AnalysisPump.ringFrames)

    private static let ringFrames = 16_384
    private static let interval: DispatchTimeInterval = .milliseconds(20)

    private let mixAnalyzer: MixAnalyzer
    private let spectrum: SpectrumAnalyzer
    private let spectrumInput: SpectrumAnalyzer
    private let focusedSpectrum: SpectrumAnalyzer
    private let focusedSpectrumInput: SpectrumAnalyzer

    private let queue = DispatchQueue(label: "com.omnilevel.analysis", qos: .userInitiated)
    private let scratchL: UnsafeMutablePointer<Float>
    private let scratchR: UnsafeMutablePointer<Float>
    private let stateLock = OSAllocatedUnfairLock()
    private var timer: DispatchSourceTimer?
    /// MixAnalyzer's momentary / short-term windows assume ~10 ms chunks.
    private var loudnessChunkFrames = 480

    init(
        mixAnalyzer: MixAnalyzer,
        spectrum: SpectrumAnalyzer,
        spectrumInput: SpectrumAnalyzer,
        focusedSpectrum: SpectrumAnalyzer,
        focusedSpectrumInput: SpectrumAnalyzer
    ) {
        self.mixAnalyzer = mixAnalyzer
        self.spectrum = spectrum
        self.spectrumInput = spectrumInput
        self.focusedSpectrum = focusedSpectrum
        self.focusedSpectrumInput = focusedSpectrumInput
        scratchL = .allocate(capacity: Self.ringFrames)
        scratchR = .allocate(capacity: Self.ringFrames)
        scratchL.initialize(repeating: 0, count: Self.ringFrames)
        scratchR.initialize(repeating: 0, count: Self.ringFrames)
    }

    deinit {
        timer?.cancel()
        scratchL.deallocate()
        scratchR.deallocate()
    }

    func setSampleRate(_ rate: Double) {
        guard rate > 0 else { return }
        stateLock.withLock { loudnessChunkFrames = max(64, Int(rate * 0.01)) }
    }

    func start() {
        stateLock.withLock {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(5))
            source.setEventHandler { [weak self] in self?.drain() }
            source.resume()
            timer = source
        }
    }

    func stop() {
        let source = stateLock.withLock { () -> DispatchSourceTimer? in
            defer { timer = nil }
            return timer
        }
        source?.cancel()
        queue.async { [postMix, preEQ, focusPre, focusPost] in
            postMix.reset()
            preEQ.reset()
            focusPre.reset()
            focusPost.reset()
        }
    }

    // MARK: - Analysis queue

    private func drain() {
        let chunk = stateLock.withLock { loudnessChunkFrames }
        while postMix.availableToRead >= chunk {
            let got = postMix.read(left: scratchL, right: scratchR, count: chunk)
            guard got > 0 else { break }
            mixAnalyzer.process(left: scratchL, right: scratchR, frameCount: got)
            spectrum.push(samples: scratchL, count: got)
        }
        drainMono(preEQ, into: spectrumInput)
        drainMono(focusPre, into: focusedSpectrumInput)
        drainMono(focusPost, into: focusedSpectrum)
    }

    private func drainMono(_ ring: StereoRingBuffer, into analyzer: SpectrumAnalyzer) {
        let available = ring.availableToRead
        guard available > 0 else { return }
        let got = ring.read(left: scratchL, right: scratchR, count: min(available, Self.ringFrames))
        if got > 0 { analyzer.push(samples: scratchL, count: got) }
    }
}
