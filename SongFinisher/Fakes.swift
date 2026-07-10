import Foundation
import Domain

/// Test/preview doubles for `AppServices.fakes()`. Never used in `.live()`.

struct FakeAudioCapturing: AudioCapturing {
    var state: AsyncStream<CaptureState> { AsyncStream { $0.yield(.idle) } }
    func start() async throws(CaptureError) -> AsyncStream<AudioChunk> { AsyncStream { $0.finish() } }
    func stop() async {}
}

struct FakeMelodyAnalyzing: MelodyAnalyzing {
    func analyze(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<AnalysisEvent> {
        AsyncStream { $0.finish() }
    }
    func analyzeFile(at url: URL, progress: @Sendable (Double) -> Void) async throws -> VoiceMemoAnalysis {
        VoiceMemoAnalysis(duration: 0, tempo: TempoEstimate(bpm: 0, confidence: 0, beatPhase: 0), phrases: [], specs: [], sections: [], repeatedPhraseGroups: [], dominantEmotions: [])
    }
}

struct FakeLyricProvider: LyricProviding {
    var kind: ProviderKind { .offline }
    func candidates(for spec: PhraseSpec, memory: SessionMemory) async throws(LyricProviderError) -> [LyricCandidate] {
        [LyricCandidate(phraseID: spec.phraseID, text: "placeholder line", syllableCount: spec.budget.target, stressAlignment: spec.budget.stressMap.pattern, provider: .offline)]
    }
}

struct FakePermissionChecking: PermissionChecking {
    func currentMicPermission() async -> MicPermission { .granted }
    func requestMicPermission() async -> MicPermission { .granted }
}
