import Foundation
import Domain

/// Builds `NoteEvent`s from pitch frames + energy onsets (docs/ARCHITECTURE.md §8):
/// a note opens on an energy onset (or unvoiced→voiced transition), closes on the next
/// onset / ≥60 ms of unvoicing / flush. Pitch-jump "onsets" close the current note and
/// open a successor flagged `isMelisma`. Notes shorter than 60 ms merge forward.
///
/// ## Vibrato-aware jump detection (Phase 4 Task 0)
/// Healthy trained vibrato runs 4.5–6.5 Hz at ±25–50 cents (Nix et al. 2016), which
/// straddles the 60-cent jump threshold, and a half-cycle lasts ~77–111 ms — far longer
/// than a naive 3-frame (30 ms) sustain. Three guards prevent vibrato from shredding a
/// sustained note into fragments:
/// 1. **Sustain ≥ 150 ms** — longer than any 4.5–6.5 Hz half-cycle, so a vibrato
///    excursion cannot stay past-threshold for a full sustain window.
/// 2. **Direction consistency** — every frame of the sustain run must deviate on the
///    same side of the note median; vibrato reverses sign every half-cycle, a true
///    note transition never comes back.
/// 3. **4–8 Hz oscillation detector** — sign flips of the deviation signal within the
///    last 250 ms at vibrato rate mark the segment as vibrato and suppress splits,
///    EXCEPT when the recent mean deviation exceeds `decisiveJumpSemitones` — a genuine
///    melisma lands far outside any vibrato extent and must split promptly even while
///    the oscillation flag is still warm from the previous note.
///
/// Not Sendable by design: confined to the analysis task/thread.
final class NoteSegmenter {
    static let unvoicedCloseFrames = 6       // 60 ms @ 100 fps
    static let pitchJumpSemitones = 0.6      // 60 cents
    /// 150 ms @ 100 fps — exceeds a 4.5 Hz vibrato half-cycle (111 ms).
    static let pitchJumpSustainFrames = 15
    /// Mean recent deviation beyond which a jump is decisive regardless of the
    /// oscillation flag: no vibrato has a ±1.2 st (240-cent peak-to-peak) extent.
    static let decisiveJumpSemitones = 1.2
    /// Sign flips of the deviation signal inside this window mark active vibrato.
    static let oscillationWindowFrames = 25  // 250 ms
    /// ≥2 flips in 250 ms ⇒ ≥4 Hz modulation (flip rate = 2× vibrato rate).
    static let oscillationMinFlips = 2
    /// Deviations inside this deadband don't count toward sign flips (pitch jitter).
    static let oscillationDeadbandSemitones = 0.08
    static let minimumNoteDuration: TimeInterval = 0.06
    /// An energy onset may only re-articulate a note at least this old — mirrors the
    /// onset detector's dead time so a duplicate fire can never carve off a fragment.
    static let minimumReArticulationAge: TimeInterval = 0.10
    /// Frames after a note opens during which pitch-jump splits are suppressed: the 64 ms
    /// analysis window plus the median filter smear the first ~100 ms of a fresh note
    /// across the previous pitch, and splitting on that glide creates phantom notes.
    static let pitchJumpGraceFrames = 10

    private struct OpenNote {
        var start: TimeInterval
        var midiSamples: [Double] = []
        var peakEnergy: Float = 0
        var isMelisma: Bool
    }

    private var openNote: OpenNote?
    private var unvoicedRun = 0
    private var jumpRun = 0
    private var jumpSign = 0
    private var recentDeviations: [Double] = []
    private var framesSinceOpen = 0
    /// An energy onset that fired on an unvoiced gap frame, latched until voicing
    /// resumes: articulation gaps often straddle a few unvoiced frames, and dropping
    /// the onset there hands the boundary to the pitch-jump path with a wrong melisma
    /// flag. The latched time becomes the note boundary.
    private var pendingOnset: (time: TimeInterval, framesLeft: Int)?

    /// Feed one frame. Returns a completed note when one closes.
    func ingest(frame: PitchFrame, energyOnset: Bool) -> NoteEvent? {
        if energyOnset {
            pendingOnset = (frame.time, 6)
        } else if let p = pendingOnset {
            pendingOnset = p.framesLeft > 1 ? (p.time, p.framesLeft - 1) : nil
        }

        guard let midi = frame.midiNote else {
            // Unvoiced frame (the onset latch persists through it).
            resetJumpTracking()
            guard openNote != nil else { return nil }
            unvoicedRun += 1
            if unvoicedRun >= Self.unvoicedCloseFrames {
                return close(at: frame.time - Double(unvoicedRun) * 0.01)
            }
            return nil
        }

        unvoicedRun = 0

        if var note = openNote {
            framesSinceOpen += 1

            // Energy onset (current or latched) while a note is sounding →
            // re-articulation: close + open fresh at the onset's own time.
            if let onset = pendingOnset, frame.time - note.start >= Self.minimumReArticulationAge {
                let boundary = max(note.start + Self.minimumNoteDuration, onset.time)
                let closed = close(at: boundary)
                openNote = OpenNote(start: boundary, midiSamples: [midi], peakEnergy: frame.rmsEnergy, isMelisma: false)
                pendingOnset = nil
                framesSinceOpen = 0
                return closed
            }

            // Grace period after opening: the 64 ms window + median filter smear the
            // first ~100 ms across the previous pitch, so accept every frame into the
            // median unconditionally — the stable majority wins — and never jump-split.
            if framesSinceOpen <= Self.pitchJumpGraceFrames {
                resetJumpTracking()
                note.midiSamples.append(midi)
                note.peakEnergy = max(note.peakEnergy, frame.rmsEnergy)
                openNote = note
                return nil
            }

            let median = Self.median(note.midiSamples) ?? midi
            let deviation = midi - median
            recentDeviations.append(deviation)
            if recentDeviations.count > Self.oscillationWindowFrames { recentDeviations.removeFirst() }

            if abs(deviation) > Self.pitchJumpSemitones {
                let sign = deviation > 0 ? 1 : -1
                if sign == jumpSign || jumpRun == 0 {
                    jumpSign = sign
                    jumpRun += 1
                } else {
                    // Direction reversed mid-run: vibrato, not a note change.
                    jumpRun = 1
                    jumpSign = sign
                }

                if jumpRun >= Self.pitchJumpSustainFrames,
                   frame.time - note.start >= Self.minimumNoteDuration,
                   !vibratoSuppressesSplit() {
                    let jumpStart = frame.time - Double(Self.pitchJumpSustainFrames) * 0.01
                    let closed = close(at: jumpStart)
                    openNote = OpenNote(start: jumpStart, midiSamples: [midi], peakEnergy: frame.rmsEnergy, isMelisma: true)
                    resetJumpTracking()
                    framesSinceOpen = 0
                    return closed
                }
            } else {
                jumpRun = 0
                jumpSign = 0
                note.midiSamples.append(midi)
                note.peakEnergy = max(note.peakEnergy, frame.rmsEnergy)
                openNote = note
            }
            return nil
        }

        // No open note: any voiced frame starts one (onset or voicing rise). Opening IS
        // the articulation, so a latched onset is consumed here.
        openNote = OpenNote(start: frame.time, midiSamples: [midi], peakEnergy: frame.rmsEnergy, isMelisma: false)
        pendingOnset = nil
        resetJumpTracking()
        framesSinceOpen = 0
        return nil
    }

    /// Closes any open note at end of stream/phrase.
    func flush(at time: TimeInterval) -> NoteEvent? {
        close(at: time)
    }

    func reset() {
        openNote = nil
        unvoicedRun = 0
        resetJumpTracking()
        framesSinceOpen = 0
        pendingOnset = nil
    }

    // MARK: - Vibrato detection

    /// True when the deviation signal oscillates at vibrato rate (≥4 Hz ⇒ ≥2 sign flips
    /// in 250 ms) AND the recent mean deviation is small enough to plausibly BE vibrato.
    /// A decisive jump (mean |deviation| > 1.2 st over the sustain window) overrides the
    /// flag — the singer has clearly moved to a different note.
    private func vibratoSuppressesSplit() -> Bool {
        let recent = recentDeviations.suffix(Self.pitchJumpSustainFrames)
        guard !recent.isEmpty else { return false }
        let meanDeviation = recent.reduce(0, +) / Double(recent.count)
        if abs(meanDeviation) > Self.decisiveJumpSemitones { return false }

        var flips = 0
        var lastSign = 0
        for deviation in recentDeviations where abs(deviation) > Self.oscillationDeadbandSemitones {
            let sign = deviation > 0 ? 1 : -1
            if lastSign != 0, sign != lastSign { flips += 1 }
            lastSign = sign
        }
        return flips >= Self.oscillationMinFlips
    }

    private func resetJumpTracking() {
        jumpRun = 0
        jumpSign = 0
        recentDeviations.removeAll(keepingCapacity: true)
    }

    private func close(at end: TimeInterval) -> NoteEvent? {
        guard let note = openNote else { return nil }
        openNote = nil
        unvoicedRun = 0

        let duration = max(0, end - note.start)
        guard duration >= Self.minimumNoteDuration, let midi = Self.median(note.midiSamples) else {
            return nil  // ornament / glitch: merged forward by simply dropping the fragment
        }

        return NoteEvent(
            onset: note.start,
            duration: duration,
            midiNote: midi,
            peakEnergy: note.peakEnergy,
            beatStrength: 0.5,       // assigned properly at phrase close, when tempo is known
            isMelisma: note.isMelisma
        )
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
