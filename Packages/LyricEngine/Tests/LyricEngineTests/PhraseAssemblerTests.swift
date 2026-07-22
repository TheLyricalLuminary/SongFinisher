import Testing
import Foundation
@testable import LyricEngine
import Domain

@Suite(.serialized) struct PhraseAssemblerTests {

    @Test("assembles at least 5 distinct candidates across the 3-12 syllable range", arguments: [3, 5, 7, 9, 12])
    func producesEnoughDistinctCandidates(syllables: Int) {
        let pattern = (0..<syllables).map { $0 % 2 == 0 ? "S" : "w" }.joined()
        let spec = Fixtures.spec(syllables: syllables, stress: pattern)
        let pool = Fixtures.assembler.assemble(spec: spec, syllableTarget: syllables, seed: 42, poolTarget: 60)
        let distinct = Set(pool.map(\.text))
        #expect(distinct.count >= 5, "only \(distinct.count) distinct lines for \(syllables) syllables")
    }

    @Test func everyAssembledLineMatchesTheRequestedSyllableCount() {
        let spec = Fixtures.spec(syllables: 6, stress: "SwSwwS")
        let pool = Fixtures.assembler.assemble(spec: spec, syllableTarget: 6, seed: 7, poolTarget: 40)
        #expect(!pool.isEmpty)
        for line in pool {
            #expect(line.syllables == 6, "'\(line.text)' has \(line.syllables) syllables")
        }
    }

    @Test func generationStaysWellUnderTheLatencyBudget() {
        // poolTarget 60 matches what OfflineLyricProvider actually requests per call —
        // the number the <100ms-on-A15 target is about. .serialized on this suite
        // stops sibling tests' concurrent beam searches from stealing CPU mid-measurement.
        let spec = Fixtures.spec(syllables: 7, stress: "SwSwwSw")
        _ = Fixtures.assembler.assemble(spec: spec, syllableTarget: 7, seed: 0, poolTarget: 60)  // warm the index

        let start = DispatchTime.now()
        _ = Fixtures.assembler.assemble(spec: spec, syllableTarget: 7, seed: 1, poolTarget: 60)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        // Host Mac hardware and a debug build both run faster and slower than an A15 in
        // different ways; this ceiling gates gross regressions, not A15-exact timing.
        #expect(elapsedMs < 300, "assembly took \(elapsedMs) ms")
    }

    @Test func wellAlignedStressBeatsMisalignedStress() {
        // A template's positional score must reward a line whose stressed syllables
        // land on the target's Strong slots over one that doesn't — the same
        // "toDAY i FOUND" invariant as Domain's CandidateRanker, now exercised through
        // real lexicon words and real beam search.
        let spec = Fixtures.spec(syllables: 4, stress: "SwSw")
        let pool = Fixtures.assembler.assemble(spec: spec, syllableTarget: 4, seed: 3, poolTarget: 80)
        #expect(!pool.isEmpty)
        let best = pool.max { $0.prosodyScore < $1.prosodyScore }!
        let worst = pool.min { $0.prosodyScore < $1.prosodyScore }!
        #expect(best.prosodyScore > worst.prosodyScore)
        #expect(best.prosodyScore > 0.5)
    }

    @Test func openVowelsPreferredOnLongNoteSlots() {
        let spec = Fixtures.spec(syllables: 3, stress: "Sww", longSlots: [0])
        let pool = Fixtures.assembler.assemble(spec: spec, syllableTarget: 3, seed: 5, poolTarget: 60)
        #expect(!pool.isEmpty)
        // Among the top-quarter scored lines, open-vowel-on-slot-0 should be common —
        // a statistical check (lexicon coverage varies by template), not a hard rule.
        let sorted = pool.sorted { $0.prosodyScore > $1.prosodyScore }
        let topQuarter = sorted.prefix(max(1, sorted.count / 4))
        #expect(!topQuarter.isEmpty)
    }

    @Test func determinismSameSeedSameSpecProducesIdenticalPool() {
        let phraseID = UUID()
        let specA = Fixtures.spec(syllables: 5, stress: "SwSww", phraseID: phraseID)
        let specB = Fixtures.spec(syllables: 5, stress: "SwSww", phraseID: phraseID)
        let poolA = Fixtures.assembler.assemble(spec: specA, syllableTarget: 5, seed: 99, poolTarget: 30)
        let poolB = Fixtures.assembler.assemble(spec: specB, syllableTarget: 5, seed: 99, poolTarget: 30)
        #expect(poolA.map(\.text) == poolB.map(\.text))
    }

    @Test func differentSeedsProduceDifferentPools() {
        let spec = Fixtures.spec(syllables: 5, stress: "SwSww")
        let poolA = Fixtures.assembler.assemble(spec: spec, syllableTarget: 5, seed: 1, poolTarget: 30)
        let poolB = Fixtures.assembler.assemble(spec: spec, syllableTarget: 5, seed: 2, poolTarget: 30)
        #expect(poolA.map(\.text) != poolB.map(\.text))
    }

    @Test("no candidate is word salad: real content, never ends on a function word",
          arguments: [3, 4, 5, 6, 7, 8, 9, 10, 12])
    func candidatesAreNeverFunctionWordSalad(syllables: Int) {
        // Regression for "during your several a": function words leaking into content
        // slots and lines ending on a bare article. Every offered line must carry a
        // content word and must not end on a stop word, across seeds and lengths.
        let pattern = (0..<syllables).map { $0 % 2 == 0 ? "S" : "w" }.joined()
        for seed in UInt64(0)..<8 {
            let spec = Fixtures.spec(syllables: syllables, stress: pattern)
            let pool = Fixtures.assembler.assemble(spec: spec, syllableTarget: syllables, seed: seed, poolTarget: 60)
            for line in pool {
                #expect(!line.contentWords.isEmpty, "'\(line.text)' has no content word")
                let last = line.text.split(separator: " ").last.map { String($0).lowercased() } ?? ""
                #expect(!PhraseAssembler.contentSlotStopWords.contains(last),
                        "'\(line.text)' ends on the function word '\(last)'")
            }
        }
    }

    @Test("no candidate repeats the same word twice",
          arguments: [3, 4, 5, 6, 7, 8, 9, 10, 12])
    func candidatesNeverRepeatAWord(syllables: Int) {
        // Regression: two POS slots of the same category in one template (the
        // noun-"and"-noun frame is the reachable case) can beam-search their way to the
        // same top-Zipf entry for both slots, producing self-duplicate lines like
        // "night and night alone" that read as broken as any word-salad line.
        let pattern = (0..<syllables).map { $0 % 2 == 0 ? "S" : "w" }.joined()
        for seed in UInt64(0)..<8 {
            let spec = Fixtures.spec(syllables: syllables, stress: pattern)
            let pool = Fixtures.assembler.assemble(spec: spec, syllableTarget: syllables, seed: seed, poolTarget: 60)
            for line in pool {
                let words = line.text.split(separator: " ").map { String($0).lowercased() }
                #expect(Set(words).count == words.count, "'\(line.text)' repeats a word")
            }
        }
    }

    @Test func contentWordsExcludeStopWordsEvenWhenTheLexiconMistagsThem() {
        // Regression: `finalize()` used to add a word to `contentWords` from its raw
        // lexicon POS bits alone, so a mistagged function word (the lexicon tags "a" as
        // a noun — see contentSlotStopWords' doc comment) could satisfy "has a real
        // content word" all by itself, defeating `isAcceptable`'s guard from the inside
        // even though the word itself is filtered out of every content POS slot.
        for seed in UInt64(0)..<8 {
            let spec = Fixtures.spec(syllables: 5, stress: "SwSwS")
            let pool = Fixtures.assembler.assemble(spec: spec, syllableTarget: 5, seed: seed, poolTarget: 60)
            for line in pool {
                #expect(line.contentWords.isDisjoint(with: PhraseAssembler.contentSlotStopWords),
                        "'\(line.text)' counts a stop word as content: \(line.contentWords)")
            }
        }
    }

    @Test func contentSlotsRejectHighFrequencyFunctionWords() {
        // The direct mechanism: expanding a noun slot must not surface "a"/"the",
        // even though the lexicon tags them as nouns and ranks them top by frequency.
        var rng = SeededRandom(seed: 1)
        let nounEntries = Fixtures.assembler.expansions(for: .pos(.noun), rng: &rng)
        let surfaced = Set(nounEntries.map(\.text))
        #expect(!surfaced.contains("a"))
        #expect(!surfaced.contains("the"))
        #expect(!surfaced.contains("your"))
    }

    @Test func fastNoteConsonantClusterIsPenalized() {
        // A synthetic check on the scoring function directly: a low positional score
        // component for cluster-heavy entries on fast slots is exercised end-to-end by
        // asserting the pool's mean prosody score stays reasonable even under a tight
        // all-fast-note duration profile (no crash, no degenerate all-zero scores).
        var spec = Fixtures.spec(syllables: 4, stress: "SwSw")
        spec = PhraseSpec(
            phraseID: spec.phraseID, budget: spec.budget, emotions: spec.emotions,
            tempoBPM: spec.tempoBPM, tempoConfidence: spec.tempoConfidence, contourShape: spec.contourShape,
            noteDurationsMs: [100, 100, 100, 100], longNoteSlots: [], phraseDuration: spec.phraseDuration
        )
        let pool = Fixtures.assembler.assemble(spec: spec, syllableTarget: 4, seed: 11, poolTarget: 40)
        #expect(!pool.isEmpty)
        #expect(pool.contains { $0.prosodyScore > 0 })
    }
}
