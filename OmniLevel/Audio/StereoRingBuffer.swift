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
        }
    }

    @discardableResult
    func write(left srcL: UnsafePointer<Float>, right srcR: UnsafePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }

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
