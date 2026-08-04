import Testing
@testable import Domain

@Suite struct SyllableCounterTests {

    // MARK: - Dictionary golden table (docs/ARCHITECTURE.md §11 trap words)

    @Test("dictionary words return their pinned syllable counts", arguments: [
        ("fire", 1), ("every", 2), ("poetry", 3), ("wandered", 2),
        ("the", 1), ("light", 1), ("forever", 3), ("everybody", 4),
        ("i'm", 1), ("don't", 1), ("isn't", 2),
    ])
    func pinnedSyllableCounts(word: String, expected: Int) {
        #expect(SyllableCounter.syllableCount(of: word) == expected)
    }

    @Test("dictionary stress patterns match hand-verified values", arguments: [
        ("every", [Stress.strong, .weak]),
        ("about", [Stress.weak, .strong]),
        ("forever", [Stress.weak, .strong, .weak]),
        ("the", [Stress.weak]),
        ("fire", [Stress.strong]),
    ])
    func pinnedStressPatterns(word: String, expected: [Stress]) {
        #expect(SyllableCounter.stressPattern(of: word) == expected)
    }

    @Test func caseInsensitiveLookup() {
        #expect(SyllableCounter.syllableCount(of: "Every") == SyllableCounter.syllableCount(of: "every"))
        #expect(SyllableCounter.syllableCount(of: "FIRE") == 1)
    }

    // MARK: - OOV heuristic fallback

    @Test("out-of-dictionary words fall back to the vowel-group heuristic", arguments: [
        ("xylophonic", 4), // 4 vowel groups: y-o-o-i (approximate but plausible)
    ])
    func oovHeuristicIsUsed(word: String, expectedApprox: Int) {
        // The heuristic is an approximation; assert it's in a sane range rather than exact.
        let count = SyllableCounter.syllableCount(of: word)
        #expect(count >= 1)
        #expect(count <= expectedApprox + 1)
    }

    @Test func oovWordAlwaysGetsAtLeastOneSyllable() {
        #expect(SyllableCounter.syllableCount(of: "zzyzx") >= 1)
        #expect(SyllableCounter.syllableCount(of: "") == 0)
    }

    @Test func oovStressDefaultsFirstSyllableStrong() {
        let pattern = SyllableCounter.stressPattern(of: "flibbertigibbet")
        #expect(pattern.first == .strong)
    }

    @Test func heuristicDropsSilentTrailingE() {
        // "shine" has vowel groups "i" and "e" but the trailing "e" is silent.
        #expect(SyllableCounter.syllableCount(of: "shine") == 1)
    }

    // MARK: - Line analysis

    @Test func lineAnalysisConcatenatesWordStressPatterns() {
        let analysis = SyllableCounter.analyze(line: "the fire waits")
        // the(w) fire(S) waits(S) = 3 syllables
        #expect(analysis.syllableCount == 3)
        #expect(analysis.stressPattern == [.weak, .strong, .strong])
    }

    @Test func lineAnalysisTailPhonemeIsLastWord() {
        let analysis = SyllableCounter.analyze(line: "I still hear your name")
        #expect(analysis.tailPhoneme == SyllableCounter.tailPhoneme(of: "name"))
    }

    @Test func emptyLineAnalysis() {
        let analysis = SyllableCounter.analyze(line: "   ")
        #expect(analysis.syllableCount == 0)
        #expect(analysis.stressPattern.isEmpty)
    }

    @Test func wordsStripsPunctuationButKeepsContractions() {
        let words = SyllableCounter.words(in: "Don't stop, please!")
        #expect(words == ["don't", "stop", "please"])
    }
}

/// Two endings a bare vowel-group count gets wrong, both ubiquitous in lyrics. The ranker
/// recounts every candidate with this heuristic and drops lines whose syllable fit misses,
/// so an over-count here rejects good lines and mis-shapes the stress pattern the melody
/// is matched against — it is the app's central promise, measured.
///
/// Every expectation below was checked against the bundled lexicon's CMUdict counts, and
/// every word takes the heuristic path rather than the pinned dictionary.
@Suite struct SyllableSuffixTests {

    @Test("\"-ed\" is silent unless it follows t or d",
          arguments: [("walked", 1), ("abandoned", 3), ("absorbed", 2), ("abused", 2),
                      ("wanted", 2), ("needed", 2), ("started", 2)])
    func edSuffix(word: String, expected: Int) {
        #expect(SyllableCounter.syllableCount(of: word) == expected,
                "'\(word)' should be \(expected) syllables")
    }

    @Test("a consonant before a final \"le\" makes it a syllable",
          arguments: [("able", 2), ("little", 2), ("gentle", 2), ("whole", 1), ("style", 1)])
    func leSuffix(word: String, expected: Int) {
        #expect(SyllableCounter.syllableCount(of: word) == expected,
                "'\(word)' should be \(expected) syllables")
    }

    @Test func shortEdWordsAreNotMisread() {
        // "red" and "bed" end in "ed" but it is the whole vowel, not a suffix.
        #expect(SyllableCounter.syllableCount(of: "red") == 1)
        #expect(SyllableCounter.syllableCount(of: "bed") == 1)
    }

    @Test func theStressPatternIsAsLongAsTheSyllableCount() {
        // The melody fit lines these up position by position, so a disagreement here would
        // silently shift every comparison the card draws.
        for word in ["walked", "abandoned", "able", "little", "wanted"] {
            let pattern = SyllableCounter.stressPattern(of: word)
            #expect(pattern.count == SyllableCounter.syllableCount(of: word),
                    "'\(word)' stress pattern and syllable count disagree")
        }
    }
}
