import Foundation
import Domain

/// Groups notes into phrases (docs/ARCHITECTURE.md §8). Boundary triggers:
/// (a) silence ≥ 350 ms — the workhorse; (b) cadence: a final note ≥ 1.5× the running
/// median duration followed by ≥ 150 ms of quiet; (c) 12 s hard cap. Phrases shorter
/// than 700 ms or with fewer than 2 notes are discarded as noise.
///
/// Not Sendable by design: confined to the analysis task/thread.
final class PhraseSegmenter {
    static let silenceBoundary: TimeInterval = 0.35
    static let cadenceQuiet: TimeInterval = 0.15
    static let cadenceLongNoteRatio = 1.5
    static let hardCap: TimeInterval = 12.0
    static let minimumDuration: TimeInterval = 0.7
    static let minimumNotes = 2

    enum Event {
        case progress(noteCount: Int)
        case completed(Phrase)
    }

    private var notes: [NoteEvent] = []
    private var phraseStart: TimeInterval?
    private var silenceStart: TimeInterval?
    private var voicedConfidences: [Float] = []
    private var phraseIndex = 0

    /// Feed one frame plus any note that just closed. Returns a phrase event or nil.
    func ingest(frame: PitchFrame, closedNote: NoteEvent?, tempo: TempoEstimate?) -> Event? {
        if let note = closedNote {
            if phraseStart == nil { phraseStart = note.onset }
            notes.append(note)
        }

        if frame.isVoiced {
            silenceStart = nil
            voicedConfidences.append(frame.confidence)
            if phraseStart == nil { phraseStart = frame.time }
            // Hard cap fires even through continuous voicing — a 20 s unbroken hum must
            // still produce phrases for the UI to react to.
            if let start = phraseStart, frame.time - start >= Self.hardCap {
                return completePhrase(endingAt: frame.time, cadence: false, tempo: tempo)
            }
            if closedNote != nil { return .progress(noteCount: notes.count) }
            return nil
        }

        // Unvoiced frame: track the silence run and test boundary rules.
        guard let start = phraseStart else { return nil }
        if silenceStart == nil { silenceStart = frame.time }
        let silenceDuration = frame.time - (silenceStart ?? frame.time)

        let cadence = isCadence()
        let boundary = silenceDuration >= Self.silenceBoundary
            || (cadence && silenceDuration >= Self.cadenceQuiet)
            || (frame.time - start) >= Self.hardCap

        guard boundary else { return nil }
        return completePhrase(endingAt: silenceStart ?? frame.time, cadence: cadence, tempo: tempo)
    }

    /// End of stream: close whatever is accumulated.
    func flush(at time: TimeInterval, tempo: TempoEstimate?) -> Event? {
        guard phraseStart != nil else { return nil }
        return completePhrase(endingAt: time, cadence: isCadence(), tempo: tempo)
    }

    func reset() {
        notes.removeAll()
        phraseStart = nil
        silenceStart = nil
        voicedConfidences.removeAll()
        phraseIndex = 0
    }

    private func isCadence() -> Bool {
        guard notes.count >= 2, let last = notes.last else { return false }
        let durations = notes.dropLast().map(\.duration).sorted()
        guard !durations.isEmpty else { return false }
        let median = durations[durations.count / 2]
        return last.duration >= median * Self.cadenceLongNoteRatio
    }

    private func completePhrase(endingAt end: TimeInterval, cadence: Bool, tempo: TempoEstimate?) -> Event? {
        defer {
            notes.removeAll()
            phraseStart = nil
            silenceStart = nil
            voicedConfidences.removeAll()
        }

        guard let start = phraseStart else { return nil }
        let phraseNotes = Self.foldMelismaArtifacts(notes)
        let duration = end - start

        guard phraseNotes.count >= Self.minimumNotes, duration >= Self.minimumDuration else {
            return nil  // discard as a false start (cough, noise, single blip)
        }

        let meanConfidence = voicedConfidences.isEmpty
            ? 0
            : Double(voicedConfidences.reduce(0, +)) / Double(voicedConfidences.count)

        let withBeats = Self.assignBeatStrengths(phraseNotes, tempo: tempo)
        let phrase = Phrase(
            index: phraseIndex,
            start: start,
            end: end,
            notes: withBeats,
            endsWithCadence: cadence,
            pitchConfidence: meanConfidence
        )
        phraseIndex += 1
        return .completed(phrase)
    }

    /// The analysis window (64 ms) spanning a note boundary produces brief gliding
    /// medians that the pitch-jump path splits into spurious melisma fragments. Fold a
    /// melisma note into its predecessor when it is too short to be an intentional
    /// melisma (< 130 ms) or lands on the predecessor's own pitch (< 0.6 st away —
    /// a same-note false split). Genuine sustained melismas survive untouched.
    static func foldMelismaArtifacts(_ notes: [NoteEvent]) -> [NoteEvent] {
        var out: [NoteEvent] = []
        for note in notes {
            if note.isMelisma, let previous = out.last,
               note.duration < 0.13 || abs(note.midiNote - previous.midiNote) < 0.6 {
                out[out.count - 1] = NoteEvent(
                    id: previous.id,
                    onset: previous.onset,
                    duration: note.end - previous.onset,
                    midiNote: previous.midiNote,
                    peakEnergy: max(previous.peakEnergy, note.peakEnergy),
                    beatStrength: previous.beatStrength,
                    isMelisma: previous.isMelisma
                )
            } else if note.isMelisma, out.isEmpty, note.duration < 0.13 {
                continue  // leading artifact with nothing to fold into
            } else {
                out.append(note)
            }
        }
        return out
    }

    /// Beat-grid alignment (docs/ARCHITECTURE.md §8): onset within ±15% of the beat period
    /// of a grid line → 1.0; near the half-beat → 0.5; otherwise 0.25. Without a reliable
    /// tempo every note keeps the neutral 0.5 the stress deriver expects.
    static func assignBeatStrengths(_ notes: [NoteEvent], tempo: TempoEstimate?) -> [NoteEvent] {
        guard let tempo, tempo.isReliable else { return notes }
        let period = tempo.beatPeriod
        return notes.map { note in
            let offset = (note.onset - tempo.beatPhase).truncatingRemainder(dividingBy: period)
            let distance = min(abs(offset), period - abs(offset))
            let halfDistance = abs(distance - period / 2)
            let strength: Float
            if distance <= period * 0.15 {
                strength = 1.0
            } else if halfDistance <= period * 0.15 {
                strength = 0.5
            } else {
                strength = 0.25
            }
            return NoteEvent(
                id: note.id,
                onset: note.onset,
                duration: note.duration,
                midiNote: note.midiNote,
                peakEnergy: note.peakEnergy,
                beatStrength: strength,
                isMelisma: note.isMelisma
            )
        }
    }
}
