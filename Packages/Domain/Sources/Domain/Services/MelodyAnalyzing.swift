import Foundation

/// What the analysis chain currently believes the input is. `melodic` is the YIN
/// single-line path (humming, singing, picking, clean arpeggios); `rhythmic` is the
/// polyphonic fallback (strummed chords), where single-F0 pitch tracking is meaningless
/// and phrases are built from the onset/accent pocket alone.
public enum InputMode: String, Sendable, Equatable, Codable {
    case melodic, rhythmic
}

/// The DSP pipeline's output events. Mic capture, a voice-memo file, and a test fixture
/// all drive the same `analyze` stream transformer (docs/ARCHITECTURE.md §5).
public enum AnalysisEvent: Sendable, Equatable {
    case pitch(PitchFrame)
    case tempoUpdated(TempoEstimate)
    case phraseInProgress(start: TimeInterval, provisionalNotes: Int)
    case phraseCompleted(Phrase)
    case inputModeChanged(InputMode)
}

public protocol MelodyAnalyzing: Sendable {
    func analyze(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<AnalysisEvent>
    func analyzeFile(at url: URL, progress: @Sendable (Double) -> Void) async throws -> VoiceMemoAnalysis
}
