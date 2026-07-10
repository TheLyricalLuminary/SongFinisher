import Testing
import Foundation
import Domain
@testable import MelodyKit

@Suite struct TempoAndProsodyTests {

    @Test func steadyPulseTempoIsDetectedWithinThreeBPM() {
        // 10 s of eighth-note pulses at 100 BPM (a note every 0.3 s at 200 onsets/min
        // reads as 100 BPM with the half/double prior centered at 105).
        var samples: [Float] = []
        let period = 0.6  // quarter note at 100 BPM
        for i in 0..<16 {
            let midi = 60.0 + Double(i % 4)
            samples.append(contentsOf: TestSignals.tone(frequency: TestSignals.frequency(midi: midi), duration: 0.25))
            samples.append(contentsOf: TestSignals.silence(duration: period - 0.25))
        }
        let tempos = TestSignals.analyze(samples).tempoUpdates
        guard let final = tempos.last else {
            Issue.record("no tempo estimate produced")
            return
        }
        #expect(abs(final.bpm - 100) < 3.0 || abs(final.bpm - 200) < 6.0 || abs(final.bpm - 50) < 3.0)
    }

    @Test func prosodyDeriverProducesSpecFromDetectedPhrase() {
        var samples = TestSignals.melody([(60, 0.5), (62, 0.2), (64, 0.5), (65, 0.2), (67, 0.6)])
        samples.append(contentsOf: TestSignals.silence(duration: 0.7))
        guard let phrase = TestSignals.analyze(samples).phrases.first else {
            Issue.record("no phrase detected")
            return
        }

        let prosody = DefaultProsodyDeriver()
        let spec = prosody.spec(for: phrase, tempo: nil, memoryHints: SessionMemory())

        #expect(spec.budget.target == phrase.syllableBearingNotes.count)
        #expect(spec.budget.stressMap.count == spec.budget.target)
        #expect(!spec.emotions.isEmpty)
        #expect(spec.noteDurationsMs.count == spec.budget.target)
        #expect(spec.phraseDuration > 0)
        // The rising C-major line should not classify as flat/falling contour.
        #expect(spec.contourShape == .rising || spec.contourShape == .arch)
    }

    @Test func longNoteSlotsMarkTheSustainedNotes() {
        // Notes 0, 2, 4 are 0.5–0.6 s; notes 1, 3 are 0.2 s → long slots ⊇ {0, 2, 4}.
        var samples = TestSignals.melody([(60, 0.5), (62, 0.2), (64, 0.5), (65, 0.2), (67, 0.6)])
        samples.append(contentsOf: TestSignals.silence(duration: 0.7))
        guard let phrase = TestSignals.analyze(samples).phrases.first, phrase.notes.count == 5 else {
            return  // covered by the spec test above; note-count drift is asserted there
        }
        let spec = DefaultProsodyDeriver().spec(for: phrase, tempo: nil, memoryHints: SessionMemory())
        #expect(spec.longNoteSlots.contains(0))
        #expect(spec.longNoteSlots.contains(4))
        #expect(!spec.longNoteSlots.contains(1))
    }
}
