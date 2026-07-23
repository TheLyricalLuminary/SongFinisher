import Foundation
import Domain

/// Per-hop orchestration of the DSP chain: sliding 1024-sample window over a 160-sample
/// (10 ms) hop at 16 kHz → YIN → flux/onsets → tempo → notes → phrases
/// (docs/ARCHITECTURE.md §8). All state lives here, confined to one task/thread; the same
/// chain instance serves the mic stream, voice-memo files, and test fixtures.
///
/// Not Sendable by design.
final class AnalysisChain {
    static let sampleRate = 16_000.0
    static let hopSize = 160
    static let windowSize = 1024

    private let pitchDetector = YINPitchDetector()
    private let onsetDetector = SpectralFluxOnsetDetector()
    private let tempoEstimator = TempoEstimator()
    private let chordDetector = ChordDetector()
    private let noteSegmenter = NoteSegmenter()
    private let phraseSegmenter = PhraseSegmenter()

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
    /// open note and phrase.
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

    func reset() {
        pitchDetector.reset()
        onsetDetector.reset()
        tempoEstimator.reset()
        chordDetector.reset()
        noteSegmenter.reset()
        phraseSegmenter.reset()
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

        // Only the tail hop is new since the previous (hopSize-shifted) window — the chord
        // detector keeps its own longer history, so feeding the whole window would
        // double-count the overlap.
        if let chord = chordDetector.ingest(hopSamples: Array(window.suffix(Self.hopSize))) {
            emit(.chordUpdated(chord))
        }

        let closedNote = noteSegmenter.ingest(frame: frame, energyOnset: energyOnset)

        switch phraseSegmenter.ingest(frame: frame, closedNote: closedNote, tempo: tempoEstimator.current) {
        case .progress(let count):
            emit(.phraseInProgress(start: time, provisionalNotes: count))
        case .completed(let phrase):
            emit(.phraseCompleted(phrase))
        case nil:
            break
        }
    }
}
