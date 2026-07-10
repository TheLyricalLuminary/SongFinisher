import Foundation
import os

/// Single-producer/single-consumer float ring buffer between the audio tap and the drain
/// thread. Storage is preallocated; overflow drops the oldest samples and counts them.
///
/// Synchronization is an `OSAllocatedUnfairLock` held across the copy rather than true
/// lock-free atomics: `Synchronization.Atomic` needs an iOS 18 floor and this project
/// targets iOS 17 (docs/ARCHITECTURE.md §10 names the ring as the codebase's one
/// `@unchecked Sendable`). The critical section is bounded (a few thousand float copies,
/// microseconds) and unfair locks carry priority donation, which protects the tap thread
/// from inversion. Swap to a true lock-free SPSC design with `Atomic<Int>` when the
/// deployment floor rises.
final class RingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private let lock = OSAllocatedUnfairLock(initialState: (head: 0, tail: 0, dropped: 0))

    /// - Parameter capacity: rounded up to the next power of two.
    init(capacity: Int) {
        var cap = 1
        while cap < capacity { cap <<= 1 }
        self.capacity = cap
        self.storage = .allocate(capacity: cap)
        storage.initialize(repeating: 0)
    }

    deinit {
        storage.deallocate()
    }

    var droppedSampleCount: Int { lock.withLock { $0.dropped } }

    /// Producer side (audio tap). Copies `count` samples in; drops oldest on overflow.
    func write(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        let mask = capacity - 1
        lock.withLockUnchecked { s in
            let free = capacity - (s.head - s.tail)
            if count > free {
                let overflow = count - free
                s.tail += overflow          // drop oldest
                s.dropped += overflow
            }
            for i in 0..<count {
                storage[(s.head + i) & mask] = samples[i]
            }
            s.head += count
        }
    }

    /// Consumer side (drain thread). Reads up to `maxCount` samples; returns actual count.
    func read(into out: UnsafeMutableBufferPointer<Float>, maxCount: Int) -> Int {
        let mask = capacity - 1
        return lock.withLockUnchecked { s in
            let available = s.head - s.tail
            let n = min(available, maxCount)
            for i in 0..<n {
                out[i] = storage[(s.tail + i) & mask]
            }
            s.tail += n
            return n
        }
    }
}
