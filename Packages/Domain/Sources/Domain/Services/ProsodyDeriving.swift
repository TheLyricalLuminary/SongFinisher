public protocol ProsodyDeriving: Sendable {
    func syllableBudget(for phrase: Phrase, tempo: TempoEstimate?) -> SyllableBudget
    func emotions(for phrase: Phrase, tempo: TempoEstimate?) -> [EmotionScore]
    /// `density` only affects rhythm-only phrases (strummed chords), where the syllable
    /// budget is the onset grid scaled by the singer's chosen lyric density; melodic
    /// phrases count one slot per note and ignore it.
    func spec(for phrase: Phrase, tempo: TempoEstimate?, memoryHints: SessionMemory, density: SyllableDensity) -> PhraseSpec
}

public extension ProsodyDeriving {
    func spec(for phrase: Phrase, tempo: TempoEstimate?, memoryHints: SessionMemory) -> PhraseSpec {
        spec(for: phrase, tempo: tempo, memoryHints: memoryHints, density: .medium)
    }
}
