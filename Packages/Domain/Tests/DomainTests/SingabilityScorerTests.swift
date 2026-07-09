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
