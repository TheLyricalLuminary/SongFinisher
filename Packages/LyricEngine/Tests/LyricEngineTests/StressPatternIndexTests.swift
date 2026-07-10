import Testing
@testable import LyricEngine

@Suite struct StressPatternIndexTests {

    @Test func candidatesMatchRequestedSyllableCount() {
        let candidates = Fixtures.index.candidates(syllables: 1, pos: .noun)
        #expect(!candidates.isEmpty)
        for id in candidates.prefix(50) {
            #expect(Fixtures.store[Int(id)].syllables == 1)
        }
    }

    @Test func candidatesCarryTheRequestedPOSBit() {
        let candidates = Fixtures.index.candidates(syllables: 2, pos: .verb)
        #expect(!candidates.isEmpty)
        for id in candidates.prefix(50) {
            #expect(!Fixtures.store[Int(id)].pos.isDisjoint(with: .verb))
        }
    }

    @Test func candidatesAreSortedByDescendingZipf() {
        let candidates = Fixtures.index.candidates(syllables: 1, pos: .verb)
        let zipfs = candidates.prefix(30).map { Fixtures.store[Int($0)].zipf }
        for i in 1..<zipfs.count {
            #expect(zipfs[i] <= zipfs[i - 1])
        }
    }

    @Test func combinedPOSUnionsWithoutDuplicates() {
        let combined = Fixtures.index.candidates(syllables: 1, pos: [.noun, .verb])
        #expect(Set(combined).count == combined.count)
    }

    @Test func unpopulatedBucketReturnsEmptyRatherThanCrashing() {
        // 8-syllable conjunctions don't exist in English; the bucket key is well-formed
        // but unpopulated, and the lookup must degrade to an empty array, not a trap.
        #expect(Fixtures.index.candidates(syllables: 8, pos: .conjunction).isEmpty)
    }
}
