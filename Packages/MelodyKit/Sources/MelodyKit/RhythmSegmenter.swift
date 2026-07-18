import Foundation
import Domain

/// The rhythmic-mode counterpart of `NoteSegmenter` + `PhraseSegmenter`: builds phrases
/// from the onset/accent pocket alone while the input is polyphonic (strummed chords).
/// A "note" here is one strum's ring-out — it opens on an energy onset and closes at
/// the next onset or when the signal decays to silence; `midiNote` is a placeholder 0
/// and the resulting phrases carry `isRhythmOnly: true` so ProsodyDeriving knows to
/// build the spec from rhythm alone.
///
/// Phrase boundaries reuse `PhraseSegmenter`'s tuning where the concept transfers:
/// silence ≥ 350 ms, 12 s hard cap, and the same discard rules for noise blips —
/// but "silence" is an RMS decay test, not a voicing test, because YIN's voicing flag
/// is meaningless while multiple strings ring.
///
/// Not Sendable by design: confined to the analysis task/thread.
final class RhythmSegmenter {
    static let silenceBoundary = PhraseSegmenter.silenceBoundary   // 0.35 s
    static let hardCap = PhraseSegmenter.hardCap                   // 12 s
    static let minimumDuration = PhraseSegmenter.minimumDuration   // 0.7 s
    static let minimumNotes = PhraseSegmenter.minimumNotes         // 2
    /// A ring-out that decays below the activity gate for this long closes the note.
    static let decayCloseTime: TimeInterval = 0.06

    enum Event {
        case progress(noteCount: Int)
        case completed(Phrase)
        /// A boundary fired but the accumulated phrase failed a discard rule. The
        /// accumulator has been reset either way; surfaced so the chain can report it.
        case discarded(PhraseDiscardReason)
    }

    private struct OpenStrum {
        var start: TimeInterval
        var peakEnergy: Float
    }

    private var openStrum: OpenStrum?
    private var notes: [NoteEvent] = []
    private var phraseStart: TimeInterval?
    private var inactiveStart: TimeInterval?
    private var phraseIndex = 0
    private var noiseFloor = NoiseFloorTracker()

    /// Feed one hop. `energyOnset` is the flux detector's verdict for this hop.
    func ingest(time: TimeInterval, rms: Float, energyOnset: Bool) -> Event? {
        let floor = noiseFloor.update(rms: rms)
        let active = rms > floor * 4

        if energyOnset {
            var closedNote: NoteEvent?
            if let strum = openStrum {
                closedNote = close(strum, at: time)
            }
            openStrum = OpenStrum(start: time, peakEnergy: rms)
            if phraseStart == nil { phraseStart = time }
            inactiveStart = nil
            if let note = closedNote { notes.append(note) }
            return .progress(noteCount: notes.count + 1)  // +1: the strum just opened
        }

        if active {
            inactiveStart = nil
            if var strum = openStrum {
                strum.peakEnergy = max(strum.peakEnergy, rms)
                openStrum = strum
            }
            // Hard cap fires even through continuous ringing.
            if let start = phraseStart, time - start >= Self.hardCap {
                return completePhrase(endingAt: time)
            }
            return nil
        }

        // Inactive hop: close a decayed ring-out, then test the phrase boundary.
        guard phraseStart != nil else { return nil }
        if inactiveStart == nil { inactiveStart = time }
        let inactiveDuration = time - (inactiveStart ?? time)

        if let strum = openStrum, inactiveDuration >= Self.decayCloseTime {
            if let note = close(strum, at: inactiveStart ?? time) { notes.append(note) }
            openStrum = nil
        }

        if inactiveDuration >= Self.silenceBoundary {
            return completePhrase(endingAt: inactiveStart ?? time)
        }
        return nil
    }

    /// End of stream or mode handoff: close whatever is accumulated.
    func flush(at time: TimeInterval) -> Event? {
        if let strum = openStrum {
            if let note = close(strum, at: time) { notes.append(note) }
            openStrum = nil
        }
        guard phraseStart != nil else { return nil }
        return completePhrase(endingAt: time)
    }

    func reset() {
        openStrum = nil
        notes.removeAll()
        phraseStart = nil
        inactiveStart = nil
        phraseIndex = 0
        noiseFloor = NoiseFloorTracker()
    }

    private func close(_ strum: OpenStrum, at end: TimeInterval) -> NoteEvent? {
        let duration = max(0, end - strum.start)
        guard duration >= NoteSegmenter.minimumNoteDuration else { return nil }
        return NoteEvent(
            onset: strum.start,
            duration: duration,
            midiNote: 0,             // placeholder: rhythm notes carry no pitch
            peakEnergy: strum.peakEnergy,
            beatStrength: 0.5        // assigned properly at phrase close, when tempo is known
        )
    }

    private func completePhrase(endingAt end: TimeInterval) -> Event? {
        // The 12 s hard cap can fire while a strum is still ringing — fold it into the
        // phrase rather than silently dropping it in the cleanup below.
        if let strum = openStrum {
            if let note = close(strum, at: end) { notes.append(note) }
            openStrum = nil
        }

        defer {
            notes.removeAll()
            phraseStart = nil
            inactiveStart = nil
            openStrum = nil
        }

        guard let start = phraseStart else { return nil }
        let duration = end - start
        // Noise (a single bump or scrape) is discarded — visibly, so the diagnostic
        // can distinguish "phrase dropped" from "boundary never fired". A lone strum
        // left to ring is 1 note and lands here by design: two strums minimum.
        guard notes.count >= Self.minimumNotes else { return .discarded(.tooFewNotes) }
        guard duration >= Self.minimumDuration else { return .discarded(.tooShort) }

        let phrase = Phrase(
            index: phraseIndex,
            start: start,
            end: end,
            notes: notes,
            endsWithCadence: false,
            pitchConfidence: 0,
            isRhythmOnly: true
        )
        phraseIndex += 1
        return .completed(phrase)
    }

    /// Beat strengths need the tempo estimate, which the chain owns — applied here so
    /// the phrase leaves MelodyKit fully formed.
    static func withBeatStrengths(_ phrase: Phrase, tempo: TempoEstimate?) -> Phrase {
        Phrase(
            id: phrase.id,
            index: phrase.index,
            start: phrase.start,
            end: phrase.end,
            notes: PhraseSegmenter.assignBeatStrengths(phrase.notes, tempo: tempo),
            endsWithCadence: phrase.endsWithCadence,
            pitchConfidence: phrase.pitchConfidence,
            isRhythmOnly: true
        )
    }
}
