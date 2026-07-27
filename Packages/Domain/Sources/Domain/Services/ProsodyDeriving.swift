public protocol ProsodyDeriving: Sendable {
    func syllableBudget(for phrase: Phrase, tempo: TempoEstimate?) -> SyllableBudget
    func emotions(for phrase: Phrase, tempo: TempoEstimate?) -> [EmotionScore]
    /// `density` only affects rhythm-only phrases (strummed chords), where the syllable
    /// budget is the onset grid scaled by the singer's chosen lyric density; melodic
    /// phrases count one slot per note and ignore it. `chord` is the harmony sounding
    /// under the phrase, if the detector had a reliable read — a bonus signal folded
    /// into emotion classification, not a requirement.
    func spec(
        for phrase: Phrase,
        tempo: TempoEstimate?,
        memoryHints: SessionMemory,
        density: SyllableDensity,
        chord: ChordEstimate?
    ) -> PhraseSpec
}

/// Protocol requirements can't carry default parameter values, so every pre-existing
/// call shape lives here as a convenience default — existing call sites (tests,
/// `MelodyAnalyzer`, rhythm-only routing without a chord read) keep compiling
/// unchanged; only callers that want both density and chord need the full signature.
public extension ProsodyDeriving {
    func spec(for phrase: Phrase, tempo: TempoEstimate?, memoryHints: SessionMemory) -> PhraseSpec {
        spec(for: phrase, tempo: tempo, memoryHints: memoryHints, density: .medium, chord: nil)
    }

    func spec(for phrase: Phrase, tempo: TempoEstimate?, memoryHints: SessionMemory, density: SyllableDensity) -> PhraseSpec {
        spec(for: phrase, tempo: tempo, memoryHints: memoryHints, density: density, chord: nil)
    }

    func spec(for phrase: Phrase, tempo: TempoEstimate?, memoryHints: SessionMemory, chord: ChordEstimate?) -> PhraseSpec {
        spec(for: phrase, tempo: tempo, memoryHints: memoryHints, density: .medium, chord: chord)
    }
}
