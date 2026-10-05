import Foundation
import os

/// SPSC stereo ring for audio. Underrun fills silence; overrun drops oldest.
/// Contiguous segments use memcpy so the lock is held only briefly.
final class StereoRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private var left: UnsafeMutablePointer<Float>
    private var right: UnsafeMutablePointer<Float>
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private let lock = OSAllocatedUnfairLock()

    /// Reader-thread-only jitter buffer state for `readForPlayback`.
    private var playbackPrimed = false
    private var fadeInPending = false
    private var resetRequested = false
    private static let fadeFrames = 128

    init(capacityFrames: Int) {
        let cap = max(1024, capacityFrames.nextPowerOfTwo)
        self.capacity = cap
        self.mask = cap - 1
        self.left = .allocate(capacity: cap)
        self.right = .allocate(capacity: cap)
        left.initialize(repeating: 0, count: cap)
        right.initialize(repeating: 0, count: cap)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    var availableToRead: Int {
        lock.withLock {
            (writeIndex - readIndex) & mask
        }
    }

    var availableToWrite: Int {
        capacity - 1 - availableToRead
    }

    func reset() {
        lock.withLock {
            writeIndex = 0
            readIndex = 0
            resetRequested = true
        }
    }

    @discardableResult
    func write(left srcL: UnsafePointer<Float>, right srcR: UnsafePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        return writeLocked(left: srcL, right: srcR, count: count)
    }

    /// Non-blocking write for realtime producers feeding non-realtime consumers:
    /// if the consumer holds the lock, the block is dropped instead of waiting.
    @discardableResult
    func tryWrite(left srcL: UnsafePointer<Float>, right srcR: UnsafePointer<Float>, count: Int) -> Int {
        guard count > 0, lock.lockIfAvailable() else { return 0 }
        defer { lock.unlock() }
        return writeLocked(left: srcL, right: srcR, count: count)
    }

    private func writeLocked(left srcL: UnsafePointer<Float>, right srcR: UnsafePointer<Float>, count: Int) -> Int {
        // Ensure room: drop oldest if needed.
        var space = (capacity - 1) - ((writeIndex - readIndex) & mask)
        if count > space {
            let drop = count - space
            readIndex = (readIndex + drop) & mask
            space = (capacity - 1) - ((writeIndex - readIndex) & mask)
        }

        var remaining = min(count, space)
        var srcOff = 0
        while remaining > 0 {
            let contiguous = min(remaining, capacity - writeIndex)
            memcpy(left.advanced(by: writeIndex), srcL.advanced(by: srcOff), contiguous * 4)
            memcpy(right.advanced(by: writeIndex), srcR.advanced(by: srcOff), contiguous * 4)
            writeIndex = (writeIndex + contiguous) & mask
            srcOff += contiguous
            remaining -= contiguous
        }
        return srcOff
    }

    @discardableResult
    func read(left dstL: UnsafeMutablePointer<Float>, right dstR: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }

        let available = (writeIndex - readIndex) & mask
        let toCopy = min(count, available)
        var dstOff = 0
        var remaining = toCopy
        while remaining > 0 {
            let contiguous = min(remaining, capacity - readIndex)
            memcpy(dstL.advanced(by: dstOff), left.advanced(by: readIndex), contiguous * 4)
            memcpy(dstR.advanced(by: dstOff), right.advanced(by: readIndex), contiguous * 4)
            readIndex = (readIndex + contiguous) & mask
            dstOff += contiguous
            remaining -= contiguous
        }
        if toCopy < count {
            let zeroCount = count - toCopy
            memset(dstL.advanced(by: toCopy), 0, zeroCount * 4)
            memset(dstR.advanced(by: toCopy), 0, zeroCount * 4)
        }
        return toCopy
    }

    /// Jitter-buffered read for the output render thread.
    ///
    /// Playback only starts (or resumes after an underrun) once `count + cushionFrames`
    /// are queued, so a capture cycle that arrives late eats into the cushion instead of
    /// producing a gap. A real underrun fades the tail out and re-primes; resuming fades
    /// in. If the queue grows past the cushion by several buffers (clock drift), it is
    /// trimmed back so latency stays bounded.
    ///
    /// Returns the number of real frames written; the remainder of `count` is silence.
    func readForPlayback(
        left dstL: UnsafeMutablePointer<Float>,
        right dstR: UnsafeMutablePointer<Float>,
        count: Int,
        cushionFrames: Int
    ) -> Int {
        guard count > 0 else { return 0 }
        let startLevel = count + cushionFrames
        let highWater = startLevel + 3 * max(count, cushionFrames)

        lock.lock()
        if resetRequested {
            resetRequested = false
            playbackPrimed = false
        }
        var available = (writeIndex - readIndex) & mask
        if !playbackPrimed {
            guard available >= startLevel else {
                lock.unlock()
                memset(dstL, 0, count * 4)
                memset(dstR, 0, count * 4)
                return 0
            }
            playbackPrimed = true
            fadeInPending = true
        }
        if available > highWater {
            readIndex = (readIndex + (available - startLevel)) & mask
            available = startLevel
            fadeInPending = true
        }

        let toCopy = min(count, available)
        var dstOff = 0
        var remaining = toCopy
        while remaining > 0 {
            let contiguous = min(remaining, capacity - readIndex)
            memcpy(dstL.advanced(by: dstOff), left.advanced(by: readIndex), contiguous * 4)
            memcpy(dstR.advanced(by: dstOff), right.advanced(by: readIndex), contiguous * 4)
            readIndex = (readIndex + contiguous) & mask
            dstOff += contiguous
            remaining -= contiguous
        }
        lock.unlock()

        if fadeInPending, toCopy > 0 {
            fadeInPending = false
            Self.applyRamp(dstL, dstR, start: 0, length: min(Self.fadeFrames, toCopy), rising: true)
        }
        if toCopy < count {
            playbackPrimed = false
            let fade = min(Self.fadeFrames, toCopy)
            Self.applyRamp(dstL, dstR, start: toCopy - fade, length: fade, rising: false)
            memset(dstL.advanced(by: toCopy), 0, (count - toCopy) * 4)
            memset(dstR.advanced(by: toCopy), 0, (count - toCopy) * 4)
        }
        return toCopy
    }

    private static func applyRamp(
        _ l: UnsafeMutablePointer<Float>,
        _ r: UnsafeMutablePointer<Float>,
        start: Int,
        length: Int,
        rising: Bool
    ) {
        guard length > 0 else { return }
        let step = 1 / Float(length)
        for i in 0..<length {
            let g = rising ? Float(i + 1) * step : Float(length - i - 1) * step
            l[start + i] *= g
            r[start + i] *= g
        }
    }
}

private extension Int {
    var nextPowerOfTwo: Int {
        guard self > 0 else { return 1 }
        var v = self - 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        v |= v >> 32
        return v + 1
    }
}
