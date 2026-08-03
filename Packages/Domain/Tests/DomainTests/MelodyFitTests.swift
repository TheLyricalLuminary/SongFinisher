import Testing
import Foundation
@testable import Domain

/// The card now shows, per syllable, whether a line's stress lands where the melody put
/// its beats. That display is only worth having if the underlying claim is true, so this
/// pins the property it advertises: a line the ranker prefers must actually agree with
/// the melody more often than one it rejects.
///
/// This is the question a songwriter asks the first time they use the app — "is it
/// calculating to my melody, or guessing?" — expressed as a test.
@Suite struct MelodyFitTests {

    private func candidate(_ text: String, stress: [Stress], phraseID: UUID = UUID()) -> LyricCandidate {
        LyricCandidate(
            phraseID: phraseID,
            text: text,
            syllableCount: stress.count,
            stressAlignment: stress,
            provider: .offline
        )
    }

    private func spec(_ pattern: [Stress]) -> PhraseSpec {
        PhraseSpec(
            phraseID: UUID(),
            budget: SyllableBudget(target: pattern.count, tolerance: 0,
                                   stressMap: StressMap(pattern: pattern)),
            emotions: [EmotionScore(emotion: .hope, confidence: 1)],
            tempoBPM: 92, tempoConfidence: 0.8, contourShape: .falling,
            noteDurationsMs: Array(repeating: 400, count: pattern.count),
            longNoteSlots: [],
            phraseDuration: Double(pattern.count) * 0.4
        )
    }

    /// Agreement per syllable is exactly what the card draws — melody mark over line mark,
    /// matched columns solid — so compute it the same way here.
    private func agreement(_ melody: [Stress], _ line: [Stress]) -> Int {
        zip(melody, line).filter { $0.0 == $0.1 }.count
    }

    @Test func theRankerPrefersTheLineThatAgreesWithTheMelody() {
        let melody: [Stress] = [.strong, .weak, .strong, .weak]
        let aligned = candidate("morning breaks again", stress: melody)
        let misaligned = candidate("a broken morning", stress: [.weak, .strong, .weak, .strong])

        #expect(agreement(melody, aligned.stressAlignment) == 4)
        #expect(agreement(melody, misaligned.stressAlignment) == 0)

        let ranked = CandidateRanker().rank([misaligned, aligned],
                                            spec: spec(melody), memory: SessionMemory())

        #expect(ranked.first?.candidate.text == aligned.text,
                "the ranker put a line that fights the melody above one that fits it")
    }

    @Test func agreementIsWhatTheCardCounts() {
        // Three of four: the caption should be able to say "3 of 4", not round it away.
        let melody: [Stress] = [.strong, .weak, .strong, .weak]
        let line: [Stress] = [.strong, .weak, .strong, .strong]
        #expect(agreement(melody, line) == 3)
    }

    @Test func aShorterLineComparesOnlyAsFarAsBothPatternsReach() {
        // Repair can return a line a syllable off the target. Zipping must not crash or
        // count phantom agreement past the end of the shorter pattern.
        let melody: [Stress] = [.strong, .weak, .strong, .weak, .strong]
        let line: [Stress] = [.strong, .weak, .strong]
        #expect(agreement(melody, line) == 3)
        #expect(Array(zip(melody, line)).count == 3, "compared past the end of the shorter pattern")
    }
}
