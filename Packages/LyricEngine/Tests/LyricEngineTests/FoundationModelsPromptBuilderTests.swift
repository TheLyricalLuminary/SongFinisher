import Testing
import Foundation
@testable import LyricEngine
import Domain

/// The prompt builder is pure string assembly, so its contract is testable everywhere —
/// including Linux CI — even though the model itself only runs on Apple Intelligence
/// hardware. These are content-presence tests, not golden strings: wording may evolve,
/// but every constraint the spec carries must reach the prompt.
@Suite struct FoundationModelsPromptBuilderTests {

    private func spec(
        target: Int = 7,
        tolerance: Int = 1,
        pattern: [Stress] = [.strong, .weak, .strong, .weak, .strong, .weak, .strong],
        emotionOverride: Emotion? = nil,
        variationSeed: String? = nil,
        longSlots: [Int] = []
    ) -> PhraseSpec {
        PhraseSpec(
            phraseID: UUID(),
            budget: SyllableBudget(target: target, tolerance: tolerance, stressMap: StressMap(pattern: pattern)),
            emotions: [EmotionScore(emotion: .longing, confidence: 0.7), EmotionScore(emotion: .reflection, confidence: 0.2)],
            tempoBPM: 92,
            tempoConfidence: 0.8,
            contourShape: .arch,
            noteDurationsMs: [200, 200, 200, 200, 200, 200, 400],
            longNoteSlots: longSlots,
            phraseDuration: 2.1,
            requestedEmotionOverride: emotionOverride,
            variationSeedText: variationSeed
        )
    }

    @Test func promptCarriesEveryObjectiveConstraint() {
        let prompt = FoundationModelsPromptBuilder.prompt(for: spec(longSlots: [2, 6]), memory: SessionMemory())
        #expect(prompt.contains("7"))
        #expect(prompt.contains("6–8"))                    // tolerance range
        #expect(prompt.contains("SwSwSwS"))                // stress display
        #expect(prompt.contains("longing"))
        #expect(prompt.contains("92 BPM"))
        #expect(prompt.contains("arch"))
        #expect(prompt.contains("syllable(s) 3, 7"))       // long slots are 1-indexed for the model
    }

    @Test func zeroToleranceAsksForExactCount() {
        let prompt = FoundationModelsPromptBuilder.prompt(for: spec(tolerance: 0), memory: SessionMemory())
        #expect(prompt.contains("exactly 7"))
        #expect(!prompt.contains("acceptable"))
    }

    @Test func emotionOverrideReplacesDerivedEmotions() {
        let prompt = FoundationModelsPromptBuilder.prompt(for: spec(emotionOverride: .tension), memory: SessionMemory())
        #expect(prompt.contains("tension"))
        #expect(!prompt.contains("longing"))
    }

    @Test func memorySectionsAppearOnlyWhenPopulated() {
        let empty = FoundationModelsPromptBuilder.prompt(for: spec(), memory: SessionMemory())
        #expect(!empty.contains("SONG SO FAR"))
        #expect(!empty.contains("rejected"))

        var memory = SessionMemory()
        memory.acceptedLines.append(LyricLine(
            phraseID: UUID(), text: "all the miles between us",
            stressMap: StressMap(pattern: [.weak, .strong]), emotion: .longing, acceptedAt: Date()
        ))
        memory.themes = ["distance", "homecoming"]
        memory.rejected.append(RejectedLine(text: "baby baby yeah", reason: .explicitReject))
        let full = FoundationModelsPromptBuilder.prompt(for: spec(), memory: memory)
        #expect(full.contains("all the miles between us"))
        #expect(full.contains("distance, homecoming"))
        #expect(full.contains("baby baby yeah"))
    }

    @Test func rejectedLinesAreCappedByMemoryLimits() {
        var memory = SessionMemory()
        for i in 0..<40 {
            memory.rejected.append(RejectedLine(text: "reject-\(i)", reason: .regenerated))
        }
        let prompt = FoundationModelsPromptBuilder.prompt(for: spec(), memory: memory)
        #expect(!prompt.contains("reject-0"))              // FIFO-capped at 20
        #expect(prompt.contains("reject-39"))
    }

    @Test func variationSeedQuotesTheExemplar() {
        let prompt = FoundationModelsPromptBuilder.prompt(for: spec(variationSeed: "paper wings on fire"), memory: SessionMemory())
        #expect(prompt.contains("\"paper wings on fire\""))
    }
}
