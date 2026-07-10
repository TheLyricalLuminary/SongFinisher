import Foundation

/// Buckets lexicon entries by (syllable count, POS category) for the assembler's
/// beam search; stress fit is checked per position at query time. Buckets are
/// sorted by descending Zipf so the beam meets common words first.
public struct StressPatternIndex: Sendable {
    private let buckets: [UInt32: [Int32]]
    private let store: LexiconStore

    public init(store: LexiconStore) {
        self.store = store
        var building: [UInt32: [Int32]] = [:]
        for i in 0..<store.count {
            let entry = store[i]
            guard entry.syllables <= 8 else { continue }
            var bits = entry.pos.rawValue
            while bits != 0 {
                let bit = bits & (~bits + 1)
                bits &= bits - 1
                let key = Self.key(syllables: entry.syllables, posBit: bit)
                building[key, default: []].append(Int32(i))
            }
        }
        for (key, indices) in building {
            building[key] = indices.sorted { store[Int($0)].zipf > store[Int($1)].zipf }
        }
        self.buckets = building
    }

    /// Word indices with exactly `syllables` syllables carrying any category in `pos`.
    /// Full, deduplicated result — for general lookups and tests. The assembler's hot
    /// path uses `topCandidates` instead: buckets routinely hold thousands of entries,
    /// and copying+deduping the whole thing on every beam-state expansion (the beam
    /// explores the same slot dozens of times) was the dominant generation cost.
    public func candidates(syllables: Int, pos: POSCategory) -> [Int32] {
        var seen = Set<Int32>()
        var out: [Int32] = []
        var bits = pos.rawValue
        while bits != 0 {
            let bit = bits & (~bits + 1)
            bits &= bits - 1
            if let bucket = buckets[Self.key(syllables: syllables, posBit: bit)] {
                for index in bucket where seen.insert(index).inserted {
                    out.append(index)
                }
            }
        }
        return out
    }

    /// The top `limit` entries (buckets are pre-sorted descending by Zipf) per set POS
    /// bit, plus `extraRandom` seeded picks from beyond that head — O(limit), never
    /// O(bucket size). Template slots are single-bit in practice, so no dedup is
    /// needed; a stray duplicate across bits is harmless (just scored twice).
    func topCandidates(syllables: Int, pos: POSCategory, limit: Int, extraRandom: Int, rng: inout SeededRandom) -> [Int32] {
        var out: [Int32] = []
        var bits = pos.rawValue
        while bits != 0 {
            let bit = bits & (~bits + 1)
            bits &= bits - 1
            guard let bucket = buckets[Self.key(syllables: syllables, posBit: bit)], !bucket.isEmpty else { continue }
            let headCount = min(limit, bucket.count)
            out.append(contentsOf: bucket[0..<headCount])
            if bucket.count > headCount, extraRandom > 0 {
                for _ in 0..<extraRandom {
                    let pick = Int(rng.next() % UInt64(bucket.count - headCount)) + headCount
                    out.append(bucket[pick])
                }
            }
        }
        return out
    }

    private static func key(syllables: Int, posBit: UInt16) -> UInt32 {
        UInt32(syllables) << 16 | UInt32(posBit)
    }
}
