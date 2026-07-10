import Foundation
import Domain

/// Builds `NoteEvent`s from pitch frames + energy onsets (docs/ARCHITECTURE.md §8):
/// a note opens on an energy onset (or unvoiced→voiced transition), closes on the next
/// onset / ≥60 ms of unvoicing / flush. Pitch-jump "onsets" (>60 cents sustained 3 frames
/// with no energy onset) close the current note and open a successor flagged `isMelisma`.
/// Notes shorter than 60 ms merge forward as ornaments.
///
/// Not Sendable by design: confined to the analysis task/thread.
final class NoteSegmenter {
    static let unvoicedCloseFrames = 6       // 60 ms @ 100 fps
    static let pitchJumpSemitones = 0.6      // 60 cents
    static let pitchJumpSustainFrames = 3
    static let minimumNoteDuration: TimeInterval = 0.06
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
    private var framesSinceOpen = 0

    /// Feed one frame. Returns a completed note when one closes.
    func ingest(frame: PitchFrame, energyOnset: Bool) -> NoteEvent? {
        guard let midi = frame.midiNote else {
            // Unvoiced frame.
            jumpRun = 0
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

            // Energy onset while a note is sounding → re-articulation: close + open fresh.
            if energyOnset, frame.time - note.start >= Self.minimumNoteDuration {
                let closed = close(at: frame.time)
                openNote = OpenNote(start: frame.time, midiSamples: [midi], peakEnergy: frame.rmsEnergy, isMelisma: false)
                framesSinceOpen = 0
                return closed
            }

            // Grace period after opening: the 64 ms window + median filter smear the
            // first ~100 ms across the previous pitch, so accept every frame into the
            // median unconditionally — the stable majority wins — and never jump-split.
            if framesSinceOpen <= Self.pitchJumpGraceFrames {
                jumpRun = 0
                note.midiSamples.append(midi)
                note.peakEnergy = max(note.peakEnergy, frame.rmsEnergy)
                openNote = note
                return nil
            }

            // Pitch-jump detection against the running note median (legato/melisma path).
            let median = Self.median(note.midiSamples) ?? midi
            if abs(midi - median) > Self.pitchJumpSemitones {
                jumpRun += 1
                if jumpRun >= Self.pitchJumpSustainFrames, frame.time - note.start >= Self.minimumNoteDuration {
                    let jumpStart = frame.time - Double(Self.pitchJumpSustainFrames) * 0.01
                    let closed = close(at: jumpStart)
                    openNote = OpenNote(start: jumpStart, midiSamples: [midi], peakEnergy: frame.rmsEnergy, isMelisma: true)
                    jumpRun = 0
                    framesSinceOpen = 0
                    return closed
                }
            } else {
                jumpRun = 0
                note.midiSamples.append(midi)
                note.peakEnergy = max(note.peakEnergy, frame.rmsEnergy)
                openNote = note
            }
            return nil
        }

        // No open note: any voiced frame starts one (onset or voicing rise).
        openNote = OpenNote(start: frame.time, midiSamples: [midi], peakEnergy: frame.rmsEnergy, isMelisma: false)
        jumpRun = 0
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
        jumpRun = 0
        framesSinceOpen = 0
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
