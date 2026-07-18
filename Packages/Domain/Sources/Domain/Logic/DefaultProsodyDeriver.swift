import Foundation

/// Composes the pure logic (StressMapDeriver, RhythmProsodyDeriver, EmotionFeatureScorer)
/// into the `PhraseSpec` handed to the AI layer. Lives in Domain because it is pure — no
/// frameworks, no I/O. Rhythm-only phrases (strummed chords) route through
/// `RhythmProsodyDeriver`: the budget is the onset grid scaled by the singer's chosen
/// density, and every pitch-derived quantity is skipped or defaulted.
public struct DefaultProsodyDeriver: ProsodyDeriving, Sendable {
    /// A note this much longer than the phrase median is a "long note" slot where the
    /// prompt asks for an open vowel (docs/ARCHITECTURE.md §9).
    static let longNoteRatio = 1.4

    public init() {}

    public func syllableBudget(for phrase: Phrase, tempo: TempoEstimate?) -> SyllableBudget {
        phrase.isRhythmOnly
            ? RhythmProsodyDeriver.deriveBudget(for: phrase, tempo: tempo, density: .medium)
            : StressMapDeriver.deriveBudget(for: phrase, tempo: tempo)
    }

    public func emotions(for phrase: Phrase, tempo: TempoEstimate?) -> [EmotionScore] {
        let features = phrase.isRhythmOnly
            ? RhythmProsodyDeriver.features(for: phrase, tempo: tempo)
            : EmotionFeatureScorer.features(for: phrase, tempo: tempo)
        return EmotionFeatureScorer.classify(features)
    }

    public func spec(for phrase: Phrase, tempo: TempoEstimate?, memoryHints: SessionMemory, density: SyllableDensity) -> PhraseSpec {
        phrase.isRhythmOnly
            ? rhythmSpec(for: phrase, tempo: tempo, density: density)
            : melodicSpec(for: phrase, tempo: tempo)
    }

    private func melodicSpec(for phrase: Phrase, tempo: TempoEstimate?) -> PhraseSpec {
        let budget = StressMapDeriver.deriveBudget(for: phrase, tempo: tempo)
        let notes = phrase.syllableBearingNotes
        let durationsMs = notes.map { Int(($0.duration * 1000).rounded()) }

        let longSlots: [Int]
        if notes.isEmpty {
            longSlots = []
        } else {
            let sorted = notes.map(\.duration).sorted()
            let median = sorted[sorted.count / 2]
            longSlots = notes.indices.filter { notes[$0].duration >= median * Self.longNoteRatio }
        }

        return PhraseSpec(
            phraseID: phrase.id,
            budget: budget,
            emotions: emotions(for: phrase, tempo: tempo),
            tempoBPM: tempo?.bpm ?? 0,
            tempoConfidence: tempo?.confidence ?? 0,
            contourShape: Self.contourShape(for: phrase),
            noteDurationsMs: durationsMs,
            longNoteSlots: longSlots,
            phraseDuration: phrase.duration
        )
    }

    private func rhythmSpec(for phrase: Phrase, tempo: TempoEstimate?, density: SyllableDensity) -> PhraseSpec {
        PhraseSpec(
            phraseID: phrase.id,
            budget: RhythmProsodyDeriver.deriveBudget(for: phrase, tempo: tempo, density: density),
            emotions: emotions(for: phrase, tempo: tempo),
            tempoBPM: tempo?.bpm ?? 0,
            tempoConfidence: tempo?.confidence ?? 0,
            contourShape: .flat,
            noteDurationsMs: RhythmProsodyDeriver.syllableDurationsMs(for: phrase, density: density),
            longNoteSlots: RhythmProsodyDeriver.longRingSlots(for: phrase, density: density),
            phraseDuration: phrase.duration
        )
    }

    /// Coarse contour label from start/end/extremum pitches (±2 semitone thresholds).
    static func contourShape(for phrase: Phrase) -> ContourShape {
        let pitches = phrase.notes.map(\.midiNote)
        guard let first = pitches.first, let last = pitches.last,
              let peak = pitches.max(), let trough = pitches.min() else { return .flat }

        let net = last - first
        if peak > max(first, last) + 2 { return .arch }
        if trough < min(first, last) - 2 { return .valley }
        if net > 2 { return .rising }
        if net < -2 { return .falling }
        return .flat
    }
}
