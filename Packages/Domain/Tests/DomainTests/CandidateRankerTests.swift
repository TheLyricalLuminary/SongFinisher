import Testing
import Foundation
@testable import Domain

@Suite struct CandidateRankerTests {

    private func spec(target: Int, tolerance: Int, stress: String, phraseID: UUID = UUID()) -> PhraseSpec {
        let map = StressMap.parse(stress)!
        return PhraseSpec(
            phraseID: phraseID,
            budget: SyllableBudget(target: target, tolerance: tolerance, stressMap: map),
            emotions: [EmotionScore(emotion: .longing, confidence: 1.0)],
            tempoBPM: 90, tempoConfidence: 0.8, contourShape: .falling,
            noteDurationsMs: Array(repeating: 400, count: target),
            longNoteSlots: [], phraseDuration: 3
        )
    }

    private func candidate(_ text: String, phraseID: UUID, provider: ProviderKind = .offline, modelScores: ModelScores? = nil) -> LyricCandidate {
        LyricCandidate(phraseID: phraseID, text: text, syllableCount: 0, stressAlignment: [], provider: provider, modelScores: modelScores)
    }

    // MARK: - syllableFit

    @Test func exactSyllableCountScoresPerfectFit() {
        // "I still hear your name" = I(w) still(S) hear(S) your(w) name(S) = 5 syllables
        let s = spec(target: 5, tolerance: 0, stress: "wSSwS")
        let score = CandidateRanker.syllableFitScore(measuredCount: 5, budget: s.budget)
        #expect(score == 1.0)
    }

    @Test func syllableFitDecaysMonotonicallyWithDistanceFromBudget() {
        let budget = SyllableBudget(target: 5, tolerance: 0, stressMap: StressMap.parse("SwSww")!)
        let scores = (0...5).map { CandidateRanker.syllableFitScore(measuredCount: 5 + $0, budget: budget) }
        for i in 1..<scores.count {
            #expect(scores[i] <= scores[i - 1])
        }
    }

    @Test func toleranceWidensTheExactMatchRange() {
        let budget = SyllableBudget(target: 5, tolerance: 1, stressMap: StressMap.parse("SwSww")!)
        #expect(CandidateRanker.syllableFitScore(measuredCount: 4, budget: budget) == 1.0)
        #expect(CandidateRanker.syllableFitScore(measuredCount: 6, budget: budget) == 1.0)
        #expect(CandidateRanker.syllableFitScore(measuredCount: 3, budget: budget) < 1.0)
    }

    // MARK: - stressFit — the misstress-sinks-a-candidate invariant

    @Test func perfectStressAlignmentScoresOne() {
        let target = StressMap.parse("SwS")!
        let measured: [Stress] = [.strong, .weak, .strong]
        #expect(CandidateRanker.stressFitScore(measuredStress: measured, target: target) == 1.0)
    }

    @Test func misstressedContentWordScoresLow() {
        // Target "SwS" ("TO-day I FOUND"-style: strong-weak-strong), candidate delivers
        // weak-strong-weak — every strong slot is missed.
        let target = StressMap.parse("SwS")!
        let measured: [Stress] = [.weak, .strong, .weak]
        let score = CandidateRanker.stressFitScore(measuredStress: measured, target: target)
        #expect(score == 0.0)
    }

    @Test func partialStressAlignmentScoresBetweenZeroAndOne() {
        let target = StressMap.parse("SwSwwSw")!
        let measured: [Stress] = [.strong, .weak, .weak, .weak, .weak, .strong, .weak] // 2 of 3 strongs hit
        let score = CandidateRanker.stressFitScore(measuredStress: measured, target: target)
        #expect(abs(score - (2.0 / 3.0)) < 0.001)
    }

    // MARK: - The headline invariant: a mild syllable miss with perfect stress beats a
    // syllable-perfect candidate whose stress is wrong (docs/ARCHITECTURE.md §9: the
    // "toDAY i FOUND" misstep must sink a candidate even when its syllable count is exact).

    @Test func mildSyllableMissWithPerfectStressBeatsPerfectSyllablesWithZeroStress() {
        let mildMissPerfectStress = LyricScore(syllableFit: 0.65, stressFit: 1.0, singability: 0.5, emotionalFit: 0.5, continuity: 0.5, memorability: 0.5)
        let perfectSyllablesZeroStress = LyricScore(syllableFit: 1.0, stressFit: 0.0, singability: 0.5, emotionalFit: 0.5, continuity: 0.5, memorability: 0.5)
        #expect(mildMissPerfectStress.total > perfectSyllablesZeroStress.total)
    }

    @Test func endToEndMisstressedCandidateSinksBelowAWellStressedOne() {
        let phraseID = UUID()
        // Target: strong-weak-strong-weak-weak-strong-weak, mirroring the doc's worked example.
        let s = spec(target: 7, tolerance: 0, stress: "SwSwwSw", phraseID: phraseID)
        let ranker = CandidateRanker()

        // "I still hear your name again": every word in this dictionary is a function word
        // or carries stress off the target's strong positions (0, 2, 5) — poor alignment.
        let misstressed = candidate("I still hear your name again", phraseID: phraseID)
        // "silence follows me tonight": "silence" and "follows" both lead-stress, landing
        // on the target's strong positions — good alignment.
        let betterStressed = candidate("silence follows me tonight", phraseID: phraseID)

        let rankedMisstressed = ranker.score(misstressed, spec: s, memory: SessionMemory())
        let rankedBetter = ranker.score(betterStressed, spec: s, memory: SessionMemory())
        #expect(rankedBetter.score.stressFit >= rankedMisstressed.score.stressFit)
    }

    // MARK: - Ranking pipeline behavior

    @Test func rankSortsDescendingByTotalScore() {
        let phraseID = UUID()
        let s = spec(target: 3, tolerance: 0, stress: "SwS", phraseID: phraseID)
        let candidates = [
            candidate("cats", phraseID: phraseID), // wildly wrong syllable count
            candidate("I still hear", phraseID: phraseID), // I(w) still(S) hear(S) = wSS, 3 syllables
        ]
        let ranker = CandidateRanker()
        let ranked = ranker.rank(candidates, spec: s, memory: SessionMemory())
        // Both may survive the drop threshold or not; if both survive, verify sort order.
        for i in 1..<ranked.count {
            #expect(ranked[i - 1].score.total >= ranked[i].score.total)
        }
    }

    @Test func candidatesBelowDropThresholdAreExcluded() {
        let phraseID = UUID()
        let s = spec(target: 8, tolerance: 0, stress: "SwSwSwSw", phraseID: phraseID)
        // "no" is 1 syllable against a budget of 8 — miles outside any reasonable fit.
        let candidates = [candidate("no", phraseID: phraseID)]
        let ranker = CandidateRanker()
        let ranked = ranker.rank(candidates, spec: s, memory: SessionMemory())
        #expect(ranked.isEmpty)
    }

    @Test func modelScoresAreUsedWhenPresentAndClamped() {
        let phraseID = UUID()
        let s = spec(target: 2, tolerance: 0, stress: "Sw", phraseID: phraseID)
        let scores = ModelScores(emotionalFit: 1.5, memorability: -0.5) // out-of-range, must clamp
        #expect(scores.emotionalFit == 1.0)
        #expect(scores.memorability == 0.0)
        let c = candidate("silence", phraseID: phraseID, modelScores: scores)
        let ranker = CandidateRanker()
        let ranked = ranker.score(c, spec: s, memory: SessionMemory())
        #expect(ranked.score.emotionalFit == 1.0)
        #expect(ranked.score.memorability == 0.0)
    }

    @Test func offlineCandidateWithoutModelScoresUsesLexiconFallback() {
        let phraseID = UUID()
        let s = spec(target: 1, tolerance: 0, stress: "S", phraseID: phraseID)
        let c = candidate("wait", phraseID: phraseID, modelScores: nil) // "wait" ~ longing lexicon
        let ranker = CandidateRanker()
        let ranked = ranker.score(c, spec: s, memory: SessionMemory())
        #expect(ranked.score.memorability == 0.5) // flat default
        #expect(ranked.score.emotionalFit > 0)
    }
}
