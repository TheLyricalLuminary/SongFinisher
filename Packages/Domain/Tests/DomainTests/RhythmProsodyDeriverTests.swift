import Testing
import Foundation
@testable import Domain

@Suite struct RhythmProsodyDeriverTests {

    private func strum(
        onset: TimeInterval,
        duration: TimeInterval,
        energy: Float = 0.5,
        beatStrength: Float = 0.5
    ) -> NoteEvent {
        // Rhythm notes carry a placeholder pitch — nothing here may depend on it.
        NoteEvent(onset: onset, duration: duration, midiNote: 0, peakEnergy: energy, beatStrength: beatStrength)
    }

    private func rhythmPhrase(notes: [NoteEvent]) -> Phrase {
        Phrase(
            index: 0,
            start: notes.first?.onset ?? 0,
            end: notes.last.map { $0.onset + $0.duration } ?? 0,
            notes: notes,
            endsWithCadence: false,
            pitchConfidence: 0,
            isRhythmOnly: true
        )
    }

    private var reliableTempo: TempoEstimate { TempoEstimate(bpm: 120, confidence: 0.8, beatPhase: 0) }

    // MARK: - Density scaling

    @Test func sparseDensityYieldsOneSyllablePerOnset() {
        let p = rhythmPhrase(notes: (0..<4).map { strum(onset: Double($0) * 0.5, duration: 0.45) })
        let budget = RhythmProsodyDeriver.deriveBudget(for: p, tempo: reliableTempo, density: .sparse)
        #expect(budget.target == 4)
    }

    @Test func mediumDensityDistributesEvenly() {
        // 1.5 × 4 onsets = 6 syllables, split 2-1-2-1 (Bresenham), never 3-1-1-1.
        #expect(RhythmProsodyDeriver.syllableGroupSizes(onsetCount: 4, density: .medium) == [2, 1, 2, 1])
        let p = rhythmPhrase(notes: (0..<4).map { strum(onset: Double($0) * 0.5, duration: 0.45) })
        let budget = RhythmProsodyDeriver.deriveBudget(for: p, tempo: reliableTempo, density: .medium)
        #expect(budget.target == 6)
    }

    @Test func denseDensityYieldsTwoSyllablesPerOnset() {
        let p = rhythmPhrase(notes: (0..<3).map { strum(onset: Double($0) * 0.5, duration: 0.45) })
        let budget = RhythmProsodyDeriver.deriveBudget(for: p, tempo: reliableTempo, density: .dense)
        #expect(budget.target == 6)
    }

    // MARK: - Stress from beat strengths

    @Test func onBeatStrumsAnchorStrongSyllables() {
        let notes = [
            strum(onset: 0.0, duration: 0.45, beatStrength: 1.0),
            strum(onset: 0.5, duration: 0.45, beatStrength: 0.25),
            strum(onset: 1.0, duration: 0.45, beatStrength: 1.0),
            strum(onset: 1.5, duration: 0.45, beatStrength: 0.25),
        ]
        let budget = RhythmProsodyDeriver.deriveBudget(for: rhythmPhrase(notes: notes), tempo: reliableTempo, density: .sparse)
        #expect(budget.stressMap.pattern == [.strong, .weak, .strong, .weak])
    }

    @Test func inBetweenSyllablesAreAlwaysWeak() {
        let notes = [
            strum(onset: 0.0, duration: 0.45, beatStrength: 1.0),
            strum(onset: 0.5, duration: 0.45, beatStrength: 1.0),
        ]
        let budget = RhythmProsodyDeriver.deriveBudget(for: rhythmPhrase(notes: notes), tempo: reliableTempo, density: .dense)
        // 2 syllables per onset: anchor, filler, anchor, filler.
        #expect(budget.stressMap.pattern == [.strong, .weak, .strong, .weak])
    }

    @Test func allWeakPromotesTheMostProminentOnset() {
        let notes = [
            strum(onset: 0.0, duration: 0.3, energy: 0.3, beatStrength: 0.25),
            strum(onset: 0.5, duration: 0.3, energy: 0.9, beatStrength: 0.25),  // loudest
            strum(onset: 1.0, duration: 0.3, energy: 0.3, beatStrength: 0.25),
        ]
        let budget = RhythmProsodyDeriver.deriveBudget(for: rhythmPhrase(notes: notes), tempo: reliableTempo, density: .sparse)
        #expect(budget.stressMap.pattern.contains(.strong))
        #expect(budget.stressMap.pattern[1] == .strong)
    }

    @Test func noteToSyllableMapsOnsetsToAnchorSlots() {
        let p = rhythmPhrase(notes: (0..<4).map { strum(onset: Double($0) * 0.5, duration: 0.45) })
        let budget = RhythmProsodyDeriver.deriveBudget(for: p, tempo: reliableTempo, density: .medium)
        // Groups 2-1-2-1 → anchors at slots 0, 2, 3, 5.
        #expect(budget.stressMap.noteToSyllable == [0, 2, 3, 5])
    }

    // MARK: - Tolerance (honest degradation)

    @Test func rhythmBudgetsNeverClaimZeroTolerance() {
        let p = rhythmPhrase(notes: (0..<4).map { strum(onset: Double($0) * 0.5, duration: 0.45) })
        let withTempo = RhythmProsodyDeriver.deriveBudget(for: p, tempo: reliableTempo, density: .sparse)
        #expect(withTempo.tolerance == 1)
        let withoutTempo = RhythmProsodyDeriver.deriveBudget(for: p, tempo: nil, density: .sparse)
        #expect(withoutTempo.tolerance == 2)
    }

    // MARK: - Long ring-outs

    @Test func longRingOutMarksItsAnchorSlot() {
        let notes = [
            strum(onset: 0.0, duration: 0.4),
            strum(onset: 0.5, duration: 1.2),  // rings out
            strum(onset: 2.0, duration: 0.4),
        ]
        let slots = RhythmProsodyDeriver.longRingSlots(for: rhythmPhrase(notes: notes), density: .sparse)
        #expect(slots == [1])
    }

    // MARK: - Spec assembly through DefaultProsodyDeriver

    @Test func rhythmSpecHasFlatContourAndDensityScaledBudget() {
        let p = rhythmPhrase(notes: (0..<4).map { strum(onset: Double($0) * 0.5, duration: 0.45) })
        let deriver = DefaultProsodyDeriver()
        let spec = deriver.spec(for: p, tempo: reliableTempo, memoryHints: SessionMemory(), density: .dense)
        #expect(spec.contourShape == .flat)
        #expect(spec.budget.target == 8)
        #expect(spec.noteDurationsMs.count == 8)
        #expect(spec.phraseID == p.id)
    }

    @Test func melodicPhrasesIgnoreDensity() {
        let notes = [
            NoteEvent(onset: 0, duration: 0.4, midiNote: 60, peakEnergy: 0.5, beatStrength: 0.5),
            NoteEvent(onset: 0.5, duration: 0.4, midiNote: 64, peakEnergy: 0.5, beatStrength: 0.5),
            NoteEvent(onset: 1.0, duration: 0.4, midiNote: 67, peakEnergy: 0.5, beatStrength: 0.5),
        ]
        let p = Phrase(index: 0, start: 0, end: 1.4, notes: notes, endsWithCadence: true, pitchConfidence: 0.9)
        let deriver = DefaultProsodyDeriver()
        let sparse = deriver.spec(for: p, tempo: reliableTempo, memoryHints: SessionMemory(), density: .sparse)
        let dense = deriver.spec(for: p, tempo: reliableTempo, memoryHints: SessionMemory(), density: .dense)
        #expect(sparse.budget.target == dense.budget.target)
        #expect(sparse.budget.target == 3)
    }

    @Test func rhythmEmotionFeaturesZeroPitchFields() {
        let p = rhythmPhrase(notes: (0..<4).map { strum(onset: Double($0) * 0.5, duration: 0.45) })
        let features = RhythmProsodyDeriver.features(for: p, tempo: reliableTempo)
        #expect(features.pitchRangeSemitones == 0)
        #expect(features.meanIntervalSemitones == 0)
        #expect(features.contourSlope == 0)
        #expect(features.endsOnDescent == 0)
        #expect(features.noteDensityPerSecond > 0)
    }

    // MARK: - Codable compatibility

    @Test func phraseWithoutRhythmKeyDecodesAsMelodic() throws {
        // A memo-analysis cache written before isRhythmOnly existed must keep decoding.
        let legacyJSON = """
        {"id":"00000000-0000-0000-0000-000000000001","index":0,"start":0,"end":1,
         "notes":[],"endsWithCadence":false,"pitchConfidence":0.5}
        """
        let phrase = try JSONDecoder().decode(Phrase.self, from: Data(legacyJSON.utf8))
        #expect(phrase.isRhythmOnly == false)
    }

    @Test func rhythmPhraseRoundTripsThroughCodable() throws {
        let p = rhythmPhrase(notes: [strum(onset: 0, duration: 0.4), strum(onset: 0.5, duration: 0.4)])
        let decoded = try JSONDecoder().decode(Phrase.self, from: JSONEncoder().encode(p))
        #expect(decoded == p)
        #expect(decoded.isRhythmOnly)
    }
}
