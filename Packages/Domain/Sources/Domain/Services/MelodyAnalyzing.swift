import Foundation

/// What the analysis chain currently believes the input is. `melodic` is the YIN
/// single-line path (humming, singing, picking, clean arpeggios); `rhythmic` is the
/// polyphonic fallback (strummed chords), where single-F0 pitch tracking is meaningless
/// and phrases are built from the onset/accent pocket alone.
public enum InputMode: String, Sendable, Equatable, Codable {
    case melodic, rhythmic
}

/// Why a candidate phrase was thrown away at its boundary instead of completing
/// (docs/ARCHITECTURE.md §8 discard rules). Surfaced as an event so the diagnostic
/// tool can show WHY the phrase counter isn't moving — a silently dropped phrase and
/// a boundary that never fired are indistinguishable from the outside otherwise.
public enum PhraseDiscardReason: String, Sendable, Equatable, Codable {
    /// Fewer than 2 notes survived segmentation (a cough, a blip, one lone strum —
    /// or a real phrase whose notes got shredded and folded away upstream).
    case tooFewNotes
    /// The phrase lasted less than the 700 ms minimum.
    case tooShort
}

/// The DSP pipeline's output events. Mic capture, a voice-memo file, and a test fixture
/// all drive the same `analyze` stream transformer (docs/ARCHITECTURE.md §5).
public enum AnalysisEvent: Sendable, Equatable {
    case pitch(PitchFrame)
    case tempoUpdated(TempoEstimate)
    case phraseInProgress(start: TimeInterval, provisionalNotes: Int)
    case phraseCompleted(Phrase)
    case phraseDiscarded(PhraseDiscardReason)
    case inputModeChanged(InputMode)
}

public protocol MelodyAnalyzing: Sendable {
    func analyze(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<AnalysisEvent>
    func analyzeFile(at url: URL, progress: @Sendable (Double) -> Void) async throws -> VoiceMemoAnalysis
}
