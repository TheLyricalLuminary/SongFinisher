import Foundation

/// The DSP pipeline's output events. Mic capture, a voice-memo file, and a test fixture
/// all drive the same `analyze` stream transformer (docs/ARCHITECTURE.md §5).
public enum AnalysisEvent: Sendable, Equatable {
    case pitch(PitchFrame)
    case tempoUpdated(TempoEstimate)
    case phraseInProgress(start: TimeInterval, provisionalNotes: Int)
    case phraseCompleted(Phrase)
}

public protocol MelodyAnalyzing: Sendable {
    func analyze(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<AnalysisEvent>
    func analyzeFile(at url: URL, progress: @Sendable (Double) -> Void) async throws -> VoiceMemoAnalysis
}
