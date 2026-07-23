import Testing
import Foundation
import Domain
@testable import LyricEngine

/// `buildPrompt` is pure string-building over `Domain` types — no FoundationModels symbols —
/// so it's testable on any machine regardless of OS version or Apple Intelligence
/// availability. The actual on-device generation call isn't unit-tested here: it's a live,
/// non-deterministic system service, not something a synthesized-fixture test can pin down
/// (docs/ARCHITECTURE.md §11). `candidatesFallsBackToOfflineProvider` instead exercises the
/// public `candidates(for:memory:)` contract end-to-end, which is honest regardless of
/// whether this machine can actually reach the on-device model.
@Suite struct OnDeviceLyricProviderTests {

    @Test func buildPromptIncludesSyllableAndStressTargets() {
        let spec = Fixtures.spec(syllables: 7, stress: "SwSwSww", tolerance: 1)
        let prompt = OnDeviceLyricProvider.buildPrompt(spec: spec, memory: SessionMemory())
        #expect(prompt.contains("Target syllable count: 7"))
        #expect(prompt.contains("tolerance ±1"))
        #expect(prompt.contains("SwSwSww"))
    }

    @Test func buildPromptIncludesRequestedEmotionOverride() {
        let spec = Fixtures.spec(syllables: 5, stress: "SwSww", emotion: .melancholy, emotionOverride: .joy)
        let prompt = OnDeviceLyricProvider.buildPrompt(spec: spec, memory: SessionMemory())
        #expect(prompt.contains("Requested emotion: joy"))
    }

    @Test func buildPromptMentionsReliableChordButNotUnreliableOne() {
        let reliable = ChordEstimate(root: 9, quality: .minor, confidence: 0.9)
        let withChord = Fixtures.spec(syllables: 5, stress: "SwSww", chord: reliable)
        let prompt = OnDeviceLyricProvider.buildPrompt(spec: withChord, memory: SessionMemory())
        #expect(prompt.contains("Am"))
        #expect(prompt.contains("minor-leaning"))

        let unreliable = ChordEstimate(root: 9, quality: .minor, confidence: 0.1)
        let withWeakChord = Fixtures.spec(syllables: 5, stress: "SwSww", chord: unreliable)
        let promptWithoutChord = OnDeviceLyricProvider.buildPrompt(spec: withWeakChord, memory: SessionMemory())
        #expect(!promptWithoutChord.contains("Harmony"))
    }

    @Test func buildPromptIncludesSessionMemoryContinuity() {
        let memory = SessionMemory(
            acceptedLines: [
                LyricLine(phraseID: UUID(), text: "all the miles between us", stressMap: StressMap(pattern: [.strong, .weak]), emotion: .longing, acceptedAt: Date()),
            ],
            rejected: [RejectedLine(text: "a line nobody liked", reason: .explicitReject)],
            themes: ["distance", "waiting"],
            dominantEmotion: .longing
        )
        let spec = Fixtures.spec(syllables: 5, stress: "SwSww")
        let prompt = OnDeviceLyricProvider.buildPrompt(spec: spec, memory: memory)
        #expect(prompt.contains("all the miles between us"))
        #expect(prompt.contains("a line nobody liked"))
        #expect(prompt.contains("distance, waiting"))
        #expect(prompt.contains("longing"))
    }

    @Test func buildPromptIncludesVariationSeedText() {
        let spec = Fixtures.spec(syllables: 5, stress: "SwSww", variationSeedText: "fade to something less")
        let prompt = OnDeviceLyricProvider.buildPrompt(spec: spec, memory: SessionMemory())
        #expect(prompt.contains("fade to something less"))
    }

    @Test func candidatesFallsBackToOfflineProvider() async throws {
        let provider = OnDeviceLyricProvider(fallback: Fixtures.offlineProvider)
        let spec = Fixtures.spec(syllables: 5, stress: "SwSww")
        let candidates = try await provider.candidates(for: spec, memory: SessionMemory())
        #expect(!candidates.isEmpty)
        // Every candidate must come from a real provider (on-device where available, offline
        // otherwise) — never silently empty, matching the pipeline's honest-degradation
        // contract for every other provider.
        for candidate in candidates {
            #expect(candidate.provider == .onDevice || candidate.provider == .offline)
        }
    }
}
