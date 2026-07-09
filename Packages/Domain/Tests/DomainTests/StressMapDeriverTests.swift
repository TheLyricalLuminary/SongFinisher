import Testing
import Foundation
@testable import Domain

@Suite struct StressMapDeriverTests {

    private func note(
        onset: TimeInterval,
        duration: TimeInterval,
        midi: Double = 60,
        energy: Float = 0.5,
        beatStrength: Float = 0.5,
        melisma: Bool = false
    ) -> NoteEvent {
        NoteEvent(onset: onset, duration: duration, midiNote: midi, peakEnergy: energy, beatStrength: beatStrength, isMelisma: melisma)
    }

    private func phrase(notes: [NoteEvent], pitchConfidence: Double = 0.9) -> Phrase {
        Phrase(index: 0, start: 0, end: notes.last.map { $0.onset + $0.duration } ?? 0, notes: notes, endsWithCadence: true, pitchConfidence: pitchConfidence)
    }

    @Test func singleNoteAlwaysGetsAtLeastOneStrongSyllable() {
        let p = phrase(notes: [note(onset: 0, duration: 0.4, beatStrength: 0.1)])
        let budget = StressMapDeriver.deriveBudget(for: p, tempo: nil)
        #expect(budget.target == 1)
        #expect(budget.stressMap.pattern == [.strong])
    }

    @Test func allEqualProminenceStillGuaranteesOneStrong() {
        // Every note identical → no note crosses the strong threshold organically;
        // the argmax-promotion rule must still produce exactly one Strong.
        let notes = (0..<4).map { i in note(onset: Double(i) * 0.3, duration: 0.3, energy: 0.4, beatStrength: 0.3) }
        let p = phrase(notes: notes)
        let budget = StressMapDeriver.deriveBudget(for: p, tempo: nil)
        #expect(budget.stressMap.pattern.filter { $0 == .strong }.count >= 1)
    }

    @Test func longLoudOnBeatNoteScoresStrong() {
        let notes = [
            note(onset: 0, duration: 0.2, energy: 0.3, beatStrength: 0.2),
            note(onset: 0.2, duration: 0.9, energy: 0.9, beatStrength: 1.0), // clearly the strong one
            note(onset: 1.1, duration: 0.2, energy: 0.3, beatStrength: 0.2),
        ]
        let tempo = TempoEstimate(bpm: 100, confidence: 0.9, beatPhase: 0)
        let p = phrase(notes: notes)
        let budget = StressMapDeriver.deriveBudget(for: p, tempo: tempo)
        #expect(budget.stressMap.pattern[1] == .strong)
    }

    @Test func melismaNotesDoNotEarnTheirOwnSlot() {
        let notes = [
            note(onset: 0, duration: 0.4, beatStrength: 0.8),
            note(onset: 0.4, duration: 0.3, beatStrength: 0.2, melisma: true), // glides off note 0
            note(onset: 0.7, duration: 0.4, beatStrength: 0.8),
        ]
        let p = phrase(notes: notes)
        let budget = StressMapDeriver.deriveBudget(for: p, tempo: nil)
        // Only 2 syllable-bearing notes → target 2, not 3.
        #expect(budget.target == 2)
        // The melisma note (index 1) maps to the same slot as note 0.
        #expect(budget.stressMap.noteToSyllable == [0, 0, 1])
    }

    @Test func missingTempoGridFallsBackToNeutralMetricAccent() {
        // With no tempo, metric accent contributes a flat 0.5 rather than crashing or
        // defaulting to 0 — duration/energy still differentiate the notes.
        let notes = [
            note(onset: 0, duration: 0.2, energy: 0.2),
            note(onset: 0.2, duration: 1.0, energy: 0.9),
        ]
        let p = phrase(notes: notes)
        let budget = StressMapDeriver.deriveBudget(for: p, tempo: nil)
        #expect(budget.stressMap.pattern[1] == .strong)
    }

    @Test func lowPitchConfidenceWidensTolerance() {
        let notes = [note(onset: 0, duration: 0.4)]
        let confident = phrase(notes: notes, pitchConfidence: 0.95)
        let unsure = phrase(notes: notes, pitchConfidence: 0.3)
        let confidentBudget = StressMapDeriver.deriveBudget(for: confident, tempo: nil)
        let unsureBudget = StressMapDeriver.deriveBudget(for: unsure, tempo: nil)
        #expect(confidentBudget.tolerance == 0)
        #expect(unsureBudget.tolerance >= 1)
    }

    @Test func unreliableTempoAlsoWidensTolerance() {
        let notes = [note(onset: 0, duration: 0.4)]
        let p = phrase(notes: notes, pitchConfidence: 0.95)
        let flakyTempo = TempoEstimate(bpm: 90, confidence: 0.1, beatPhase: 0)
        let budget = StressMapDeriver.deriveBudget(for: p, tempo: flakyTempo)
        #expect(budget.tolerance >= 1)
    }

    @Test func emptyPhraseProducesZeroBudget() {
        let p = phrase(notes: [])
        let budget = StressMapDeriver.deriveBudget(for: p, tempo: nil)
        #expect(budget.target == 0)
        #expect(budget.stressMap.pattern.isEmpty)
    }

    @Test func sevenSyllableGoldenExample() {
        // Mirrors the architecture doc's worked example: 7 notes, alternating strong/weak
        // via clear duration+energy differentiation, expected pattern S w S w w S w.
        let strengths: [(Float, Float)] = [(0.9, 1.0), (0.3, 0.2), (0.9, 1.0), (0.3, 0.2), (0.3, 0.2), (0.9, 1.0), (0.3, 0.2)]
        var t = 0.0
        let notes = strengths.map { (energy, beat) -> NoteEvent in
            let duration = beat > 0.5 ? 0.5 : 0.2
            let n = note(onset: t, duration: duration, energy: energy, beatStrength: beat)
            t += duration
            return n
        }
        let tempo = TempoEstimate(bpm: 100, confidence: 0.9, beatPhase: 0)
        let p = phrase(notes: notes)
        let budget = StressMapDeriver.deriveBudget(for: p, tempo: tempo)
        #expect(budget.target == 7)
        #expect(budget.stressMap.display == "SwSwwSw")
    }
}
