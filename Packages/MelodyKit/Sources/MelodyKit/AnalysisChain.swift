import Foundation
import Domain

/// Per-hop orchestration of the DSP chain: sliding 1024-sample window over a 160-sample
/// (10 ms) hop at 16 kHz → YIN → flux/onsets → tempo → notes → phrases
/// (docs/ARCHITECTURE.md §8). All state lives here, confined to one task/thread; the same
/// chain instance serves the mic stream, voice-memo files, and test fixtures.
///
/// ## Hybrid melodic/rhythmic routing
/// The `PolyphonyDetector` watches every energetic hop. While the input is a single
/// line (hum, voice, picking) the chain runs the YIN note/phrase path unchanged. When
/// it turns polyphonic (strummed chords) the pitch path is meaningless, so hops route
/// to the `RhythmSegmenter` instead, which builds `isRhythmOnly` phrases from the
/// onset/accent pocket. YIN and the tempo estimator keep running in both modes — the
/// pitch frames feed the detector and the UI meters, and tempo tracks the flux envelope
/// regardless of polyphony. Mode flips flush the outgoing segmenter first (its phrase,
/// if any, is emitted before the `inputModeChanged` event).
///
/// Not Sendable by design.
final class AnalysisChain {
    static let sampleRate = 16_000.0
    static let hopSize = 160
    static let windowSize = 1024

    private let pitchDetector = YINPitchDetector()
    private let onsetDetector = SpectralFluxOnsetDetector()
    private let tempoEstimator = TempoEstimator()
    private let noteSegmenter = NoteSegmenter()
    private let phraseSegmenter = PhraseSegmenter()
    private let polyphonyDetector = PolyphonyDetector()
    private let rhythmSegmenter = RhythmSegmenter()

    private var mode: InputMode = .melodic
    private var pending: [Float] = []
    private var hopIndex = 0

    /// Feed samples; emits events as complete hops become available.
    func process(samples: [Float], emit: (AnalysisEvent) -> Void) {
        pending.append(contentsOf: samples)

        while pending.count >= Self.windowSize {
            let window = Array(pending.prefix(Self.windowSize))
            step(window: window, emit: emit)
            pending.removeFirst(Self.hopSize)
        }
    }

    /// End of stream: pad the tail with silence to flush the pipeline, then close any
    /// open note and phrase in whichever mode is active.
    func flush(emit: (AnalysisEvent) -> Void) {
        if !pending.isEmpty {
            let padded = pending + [Float](repeating: 0, count: Self.windowSize)
            pending = padded
            while pending.count >= Self.windowSize {
                let window = Array(pending.prefix(Self.windowSize))
                step(window: window, emit: emit)
                pending.removeFirst(Self.hopSize)
            }
        }

        let time = currentTime
        switch mode {
        case .melodic:
            flushMelodic(at: time, emit: emit)
        case .rhythmic:
            flushRhythmic(at: time, emit: emit)
        }
    }

    func reset() {
        pitchDetector.reset()
        onsetDetector.reset()
        tempoEstimator.reset()
        noteSegmenter.reset()
        phraseSegmenter.reset()
        polyphonyDetector.reset()
        rhythmSegmenter.reset()
        mode = .melodic
        pending.removeAll()
        hopIndex = 0
    }

    private var currentTime: TimeInterval {
        Double(hopIndex) * Double(Self.hopSize) / Self.sampleRate
    }

    private func step(window: [Float], emit: (AnalysisEvent) -> Void) {
        let time = currentTime
        hopIndex += 1

        let frame = pitchDetector.process(window: window, time: time)
        emit(.pitch(frame))

        let energyOnset = onsetDetector.process(window: window)
        if let tempo = tempoEstimator.ingest(fluxValue: onsetDetector.latestFlux, time: time) {
            emit(.tempoUpdated(tempo))
        }

        if let newMode = polyphonyDetector.ingest(magnitudes: onsetDetector.latestMagnitudes, frame: frame) {
            switchMode(to: newMode, at: time, emit: emit)
        }

        switch mode {
        case .melodic:
            let closedNote = noteSegmenter.ingest(frame: frame, energyOnset: energyOnset)
            switch phraseSegmenter.ingest(frame: frame, closedNote: closedNote, tempo: tempoEstimator.current) {
            case .progress(let count):
                emit(.phraseInProgress(start: time, provisionalNotes: count))
            case .completed(let phrase):
                emit(.phraseCompleted(phrase))
            case nil:
                break
            }

        case .rhythmic:
            switch rhythmSegmenter.ingest(time: time, rms: frame.rmsEnergy, energyOnset: energyOnset) {
            case .progress(let count):
                emit(.phraseInProgress(start: time, provisionalNotes: count))
            case .completed(let phrase):
                emit(.phraseCompleted(RhythmSegmenter.withBeatStrengths(phrase, tempo: tempoEstimator.current)))
            case nil:
                break
            }
        }
    }

    /// Flushes the outgoing mode's segmenter (emitting its phrase, if one survives the
    /// discard rules, BEFORE the mode-change event) and announces the new mode.
    private func switchMode(to newMode: InputMode, at time: TimeInterval, emit: (AnalysisEvent) -> Void) {
        guard newMode != mode else { return }
        switch mode {
        case .melodic:
            flushMelodic(at: time, emit: emit)
        case .rhythmic:
            flushRhythmic(at: time, emit: emit)
        }
        mode = newMode
        emit(.inputModeChanged(newMode))
    }

    private func flushMelodic(at time: TimeInterval, emit: (AnalysisEvent) -> Void) {
        let tempo = tempoEstimator.current
        if let closed = noteSegmenter.flush(at: time) {
            if case .completed(let phrase)? = phraseSegmenter.ingest(
                frame: PitchFrame(time: time, frequencyHz: nil, midiNote: nil, rmsEnergy: 0, confidence: 0),
                closedNote: closed,
                tempo: tempo
            ) {
                emit(.phraseCompleted(phrase))
            }
        }
        if case .completed(let phrase)? = phraseSegmenter.flush(at: time, tempo: tempo) {
            emit(.phraseCompleted(phrase))
        }
    }

    private func flushRhythmic(at time: TimeInterval, emit: (AnalysisEvent) -> Void) {
        if case .completed(let phrase)? = rhythmSegmenter.flush(at: time) {
            emit(.phraseCompleted(RhythmSegmenter.withBeatStrengths(phrase, tempo: tempoEstimator.current)))
        }
    }
}
