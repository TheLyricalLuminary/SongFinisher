public protocol ProsodyDeriving: Sendable {
    func syllableBudget(for phrase: Phrase, tempo: TempoEstimate?) -> SyllableBudget
    func emotions(for phrase: Phrase, tempo: TempoEstimate?) -> [EmotionScore]
    func spec(for phrase: Phrase, tempo: TempoEstimate?, memoryHints: SessionMemory, chord: ChordEstimate?) -> PhraseSpec
}

/// Protocol requirements can't carry default parameter values, so the pre-chord 3-param
/// `spec(for:tempo:memoryHints:)` shape lives here as a convenience default (`chord: nil`)
/// — existing call sites (tests, `MelodyAnalyzer`) keep compiling unchanged, only callers
/// that want chord-aware emotion scoring need to pass the new parameter.
public extension ProsodyDeriving {
    func spec(for phrase: Phrase, tempo: TempoEstimate?, memoryHints: SessionMemory) -> PhraseSpec {
        spec(for: phrase, tempo: tempo, memoryHints: memoryHints, chord: nil)
    }
}
