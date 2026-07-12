import Testing
import Foundation
import Domain
@testable import LyricEngine

@Suite struct OfflineLyricProviderTests {

    @Test func returnsFiveCandidatesForAnOrdinarySpec() async throws {
        let provider = OfflineLyricProvider(store: Fixtures.store)
        let spec = Fixtures.spec(syllables: 7, stress: "SwSwwSw")
        let candidates = try await provider.candidates(for: spec, memory: SessionMemory())
        #expect(candidates.count == 5)
        for c in candidates {
            #expect(c.provider == .offline)
            #expect(c.phraseID == spec.phraseID)
        }
    }

    @Test func neverThrowsForAnyBudgetInOneToTwelve() async {
        let provider = OfflineLyricProvider(store: Fixtures.store)
        for syllables in 1...12 {
            let pattern = (0..<syllables).map { $0 == 0 ? "S" : "w" }.joined()
            let spec = Fixtures.spec(syllables: syllables, stress: pattern, tolerance: 2)
            do {
                let candidates = try await provider.candidates(for: spec, memory: SessionMemory())
                #expect(!candidates.isEmpty, "no candidates for \(syllables) syllables")
            } catch {
                Issue.record("threw for \(syllables) syllables: \(error)")
            }
        }
    }

    /// Regression: a confident phrase (zero tolerance) budgeted at 1–2 syllables used to
    /// throw `invalidResponse`, because every template needs at least 3 slots — the
    /// existing "1...12" sweep above always used tolerance 2, which masked this by
    /// reaching a 3-syllable search step within the declared tolerance.
    @Test func neverThrowsForZeroToleranceOneOrTwoSyllableBudget() async {
        let provider = OfflineLyricProvider(store: Fixtures.store)
        for syllables in [1, 2] {
            let pattern = (0..<syllables).map { $0 == 0 ? "S" : "w" }.joined()
            let spec = Fixtures.spec(syllables: syllables, stress: pattern, tolerance: 0)
            do {
                let candidates = try await provider.candidates(for: spec, memory: SessionMemory())
                #expect(!candidates.isEmpty, "no candidates for \(syllables) syllables at zero tolerance")
            } catch {
                Issue.record("threw for \(syllables) syllables at zero tolerance: \(error)")
            }
        }
    }

    @Test func sameInputAndAttemptCountProducesIdenticalOutput() async throws {
        let provider = OfflineLyricProvider(store: Fixtures.store)
        let phraseID = UUID()
        let specA = Fixtures.spec(syllables: 6, stress: "SwSwwS", phraseID: phraseID)
        let specB = Fixtures.spec(syllables: 6, stress: "SwSwwS", phraseID: phraseID)
        let memory = SessionMemory()
        let a = try await provider.candidates(for: specA, memory: memory)
        let b = try await provider.candidates(for: specB, memory: memory)
        #expect(a.map(\.text) == b.map(\.text))
    }

    @Test func regenerateAttemptProducesDifferentCandidates() async throws {
        // Each Regenerate records a rejection, growing memory.rejected — the seed input
        // — so tapping Regenerate must walk to different output without any new
        // protocol surface.
        let provider = OfflineLyricProvider(store: Fixtures.store)
        let phraseID = UUID()
        let spec = Fixtures.spec(syllables: 6, stress: "SwSwwS", phraseID: phraseID)
        let first = try await provider.candidates(for: spec, memory: SessionMemory())

        var regenerated = SessionMemory()
        regenerated.rejected = [RejectedLine(text: first[0].text, reason: .regenerated)]
        let second = try await provider.candidates(for: spec, memory: regenerated)

        #expect(first.map(\.text) != second.map(\.text))
    }

    @Test func differentEmotionOverrideChangesTheSeed() {
        let spec = Fixtures.spec(syllables: 6, stress: "SwSwwS", emotion: .longing)
        let base = OfflineLyricProvider.seed(for: spec, memory: SessionMemory())
        let overridden = Fixtures.spec(syllables: 6, stress: "SwSwwS", emotion: .longing, emotionOverride: .joy)
        let overriddenSeed = OfflineLyricProvider.seed(for: overridden, memory: SessionMemory())
        #expect(base != overriddenSeed)
    }

    @Test func moreLikeThisBiasesSelectionTowardTheSeedLinesWords() {
        // Exercises selectVariations directly against a controlled pool so the
        // overlap-bonus mechanism is asserted precisely, independent of what the
        // lexicon happens to generate for a given spec.
        let onTheme = AssembledLine(
            text: "the light still burns", syllables: 4, stressPattern: [],
            prosodyScore: 0.6, fluencyScore: 0.5, emotionScore: 0.5,
            contentWords: ["light", "burns"]
        )
        let offTheme = AssembledLine(
            text: "a stranger walks alone", syllables: 4, stressPattern: [],
            prosodyScore: 0.6, fluencyScore: 0.5, emotionScore: 0.5,
            contentWords: ["stranger", "walks", "alone"]
        )
        let picked = OfflineLyricProvider.selectVariations(
            of: "the light still shines bright",
            from: [offTheme, onTheme],
            count: 1
        )
        #expect(picked.first?.text == "the light still burns")
    }

    @Test func zeroSyllableBudgetDoesNotCrash() async {
        let provider = OfflineLyricProvider(store: Fixtures.store)
        let spec = Fixtures.spec(syllables: 0, stress: "", tolerance: 1)
        do {
            _ = try await provider.candidates(for: spec, memory: SessionMemory())
        } catch {
            // Either an empty-but-valid response or a graceful error is acceptable;
            // a crash is the only failure mode this test guards against.
        }
    }
}
