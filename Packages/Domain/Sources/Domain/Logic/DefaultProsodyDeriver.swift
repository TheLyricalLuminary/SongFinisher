import Foundation

/// Composes the pure logic (StressMapDeriver, EmotionFeatureScorer) into the `PhraseSpec`
/// handed to the AI layer. Lives in Domain because it is pure — no frameworks, no I/O.
public struct DefaultProsodyDeriver: ProsodyDeriving, Sendable {
    /// A note this much longer than the phrase median is a "long note" slot where the
    /// prompt asks for an open vowel (docs/ARCHITECTURE.md §9).
    static let longNoteRatio = 1.4

    public init() {}

    public func syllableBudget(for phrase: Phrase, tempo: TempoEstimate?) -> SyllableBudget {
        StressMapDeriver.deriveBudget(for: phrase, tempo: tempo)
    }

    public func emotions(for phrase: Phrase, tempo: TempoEstimate?) -> [EmotionScore] {
        EmotionFeatureScorer.classify(EmotionFeatureScorer.features(for: phrase, tempo: tempo))
    }

    public func spec(for phrase: Phrase, tempo: TempoEstimate?, memoryHints: SessionMemory, chord: ChordEstimate?) -> PhraseSpec {
        let budget = syllableBudget(for: phrase, tempo: tempo)
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

        let emotions = EmotionFeatureScorer.classify(
            EmotionFeatureScorer.features(for: phrase, tempo: tempo),
            chord: chord
        )

        return PhraseSpec(
            phraseID: phrase.id,
            budget: budget,
            emotions: emotions,
            tempoBPM: tempo?.bpm ?? 0,
            tempoConfidence: tempo?.confidence ?? 0,
            contourShape: Self.contourShape(for: phrase),
            noteDurationsMs: durationsMs,
            longNoteSlots: longSlots,
            phraseDuration: phrase.duration,
            chord: chord
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
