import Testing
import Foundation
import Domain
@testable import SongFinisher

/// On hardware with no AI tier, `AppServices.lyrics` IS the offline assembler — the
/// premium gate meters nothing there, and the "free AI lines used" upsell would promise
/// lines the device can't produce. These tests pin that contract from both sides: the
/// gate is never consulted when premium isn't real, and still meters when it is.
@MainActor struct PremiumGatingTests {

    /// Counts consultations so tests can distinguish "gate said no" from "gate skipped".
    private final class GatingSpy: GenerationGating {
        private(set) var calls = 0
        let allow: Bool
        init(allow: Bool) { self.allow = allow }
        func allowPremiumGeneration() -> Bool {
            calls += 1
            return allow
        }
    }

    /// Stands in for the AI tier: a distinct `kind` and text so tests can tell which
    /// provider actually generated.
    private struct FakePremiumProvider: LyricProviding {
        var kind: ProviderKind { .appleIntelligence }
        func candidates(for spec: PhraseSpec, memory: SessionMemory) async throws(LyricProviderError) -> [LyricCandidate] {
            [LyricCandidate(
                phraseID: spec.phraseID, text: "premium line",
                syllableCount: spec.budget.target, stressAlignment: spec.budget.stressMap.pattern,
                provider: .appleIntelligence
            )]
        }
    }

    /// Emits one completed phrase and leaves the stream open — finishing it would race
    /// the pipeline's `state = .idle` against the generation task's `.suggesting`.
    private struct PhraseEmittingAnalyzer: MelodyAnalyzing {
        let phrase: Phrase
        func analyze(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<AnalysisEvent> {
            AsyncStream { continuation in
                continuation.yield(.phraseCompleted(phrase))
            }
        }
        func analyzeFile(at url: URL, progress: @Sendable (Double) -> Void) async throws -> VoiceMemoAnalysis {
            VoiceMemoAnalysis(duration: 0, tempo: TempoEstimate(bpm: 0, confidence: 0, beatPhase: 0), phrases: [], specs: [], sections: [], repeatedPhraseGroups: [], dominantEmotions: [])
        }
    }

    private static func fourNotePhrase() -> Phrase {
        let notes = (0..<4).map { i in
            NoteEvent(onset: Double(i) * 0.4, duration: 0.3, midiNote: 60 + Double(i), peakEnergy: 0.6, beatStrength: 0.5)
        }
        return Phrase(index: 0, start: 0, end: 1.6, notes: notes, endsWithCadence: true, pitchConfidence: 0.9)
    }

    private static func startAndAwaitSuggestion(_ viewModel: SessionViewModel) async {
        viewModel.start()
        let deadline = Date().addingTimeInterval(5)
        while viewModel.rankedCandidates.isEmpty && viewModel.generationError == nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func noAITierNeverConsultsTheGate() async {
        let gating = GatingSpy(allow: false)
        // `.fakes()` default lyrics provider has kind `.offline` — the no-AI-tier shape.
        let viewModel = SessionViewModel(
            services: .fakes(analyzer: PhraseEmittingAnalyzer(phrase: Self.fourNotePhrase())),
            gating: gating
        )

        await Self.startAndAwaitSuggestion(viewModel)

        #expect(!viewModel.rankedCandidates.isEmpty)
        #expect(gating.calls == 0)
        #expect(viewModel.didHitFreeLimit == false)
        viewModel.stop()
    }

    @Test func aiTierStillMetersAndDegradesToOffline() async {
        let gating = GatingSpy(allow: false)
        let viewModel = SessionViewModel(
            services: .fakes(
                analyzer: PhraseEmittingAnalyzer(phrase: Self.fourNotePhrase()),
                lyrics: FakePremiumProvider()
            ),
            gating: gating
        )

        await Self.startAndAwaitSuggestion(viewModel)

        #expect(gating.calls == 1)
        #expect(viewModel.didHitFreeLimit == true)
        #expect(viewModel.rankedCandidates.first?.candidate.provider == .offline)
        viewModel.stop()
    }

    @Test func aiTierRunsPremiumWhenTheGateAllows() async {
        let gating = GatingSpy(allow: true)
        let viewModel = SessionViewModel(
            services: .fakes(
                analyzer: PhraseEmittingAnalyzer(phrase: Self.fourNotePhrase()),
                lyrics: FakePremiumProvider()
            ),
            gating: gating
        )

        await Self.startAndAwaitSuggestion(viewModel)

        #expect(gating.calls == 1)
        #expect(viewModel.didHitFreeLimit == false)
        #expect(viewModel.rankedCandidates.first?.candidate.provider == .appleIntelligence)
        viewModel.stop()
    }
}
