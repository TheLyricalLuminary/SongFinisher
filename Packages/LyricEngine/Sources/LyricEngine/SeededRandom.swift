import Foundation

/// SplitMix64 — deterministic, seedable, tiny. Same seed → same sequence, so
/// offline suggestions are reproducible and exact-match testable.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum Seeding {
    /// FNV-1a over arbitrary bytes — stable across launches (unlike `Hasher`).
    static func fnv(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xCBF29CE484222325
        for b in bytes {
            hash ^= UInt64(b)
            hash = hash &* 0x100000001B3
        }
        return hash
    }

    static func fnv(_ text: String) -> UInt64 { fnv(Array(text.utf8)) }
}
