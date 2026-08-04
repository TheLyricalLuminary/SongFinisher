import Testing
import Foundation
@testable import Domain

@Suite struct SingabilityScorerTests {

    private func spec(longNoteSlots: [Int], target: Int) -> PhraseSpec {
        PhraseSpec(
            phraseID: UUID(),
            budget: SyllableBudget(target: target, tolerance: 1, stressMap: StressMap(pattern: Array(repeating: .weak, count: target))),
            emotions: [], tempoBPM: 90, tempoConfidence: 0.8, contourShape: .flat,
            noteDurationsMs: Array(repeating: 400, count: target),
            longNoteSlots: longNoteSlots, phraseDuration: 3
        )
    }

    @Test func openVowelOnLongSlotScoresHigherThanClosedVowel() {
        // "go" (open 'o') vs "grip" (closed, no open vowel) — single syllable each, slot 0 is long.
        let s = spec(longNoteSlots: [0], target: 1)
        let openScore = SingabilityScorer.score(text: "go", spec: s)
        let closedScore = SingabilityScorer.score(text: "grip", spec: s)
        #expect(openScore > closedScore)
    }

    @Test func consonantClusterPenalizesScore() {
        let s = spec(longNoteSlots: [], target: 1)
        let clustered = SingabilityScorer.score(text: "strengths", spec: s) // "ngths" cluster
        let simple = SingabilityScorer.score(text: "day", spec: s)
        #expect(clustered < simple)
    }

    @Test func emptyTextScoresZero() {
        let s = spec(longNoteSlots: [], target: 1)
        #expect(SingabilityScorer.score(text: "", spec: s) == 0)
    }

    @Test func scoreIsAlwaysInUnitRange() {
        let s = spec(longNoteSlots: [0, 1, 2], target: 3)
        let score = SingabilityScorer.score(text: "strengths strengths strengths", spec: s)
        #expect(score >= 0)
        #expect(score <= 1)
    }

    @Test func nonLongSlotsAreNeutralRegardlessOfVowel() {
        // No long slots declared → every syllable gets the flat neutral base score
        // (only cluster penalties still apply).
        let s = spec(longNoteSlots: [], target: 1)
        let openScore = SingabilityScorer.score(text: "go", spec: s)
        let closedScore = SingabilityScorer.score(text: "hem", spec: s)
        #expect(openScore == closedScore)
    }
}

/// The vowel half of "lyrics that fit the melody": a held note wants an open, sustainable
/// nucleus. Domain has no phoneme data, so this reads spelling — and the rule it replaced
/// ("contains an a or an o") called every one of the words below closed, which meant the
/// ranker penalised the assembler's best picks for long notes.
@Suite struct OpenNucleusTests {

    @Test("the words a singer actually holds are open",
          arguments: ["sky", "high", "time", "eye", "my", "try", "fly",
                      "light", "night", "fire", "day", "go", "home", "alone"])
    func singableWordsReadAsOpen(word: String) {
        #expect(SingabilityScorer.hasOpenNucleus(word), "'\(word)' is singable on a long note")
    }

    @Test("tight, closed nuclei stay closed",
          arguments: ["free", "keep", "this", "sit", "been", "green", "week"])
    func closedWordsReadAsClosed(word: String) {
        #expect(!SingabilityScorer.hasOpenNucleus(word), "'\(word)' is not an open nucleus")
    }

    @Test func anOpenVowelOnALongNoteOutscoresAClosedOne() {
        // The property the rule exists to serve, end to end through the scorer.
        let pattern = StressMap(pattern: [.strong, .weak])
        let spec = PhraseSpec(
            phraseID: UUID(),
            budget: SyllableBudget(target: 2, tolerance: 0, stressMap: pattern),
            emotions: [EmotionScore(emotion: .hope, confidence: 1)],
            tempoBPM: 90, tempoConfidence: 0.8, contourShape: .falling,
            noteDurationsMs: [900, 300],
            longNoteSlots: [0],
            phraseDuration: 1.2
        )
        let open = SingabilityScorer.score(text: "sky fell", spec: spec)
        let closed = SingabilityScorer.score(text: "wit fell", spec: spec)
        #expect(open > closed, "a held 'sky' should beat a held 'wit' on a long first note")
    }
}
