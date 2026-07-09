public protocol ProsodyDeriving: Sendable {
    func syllableBudget(for phrase: Phrase, tempo: TempoEstimate?) -> SyllableBudget
    func emotions(for phrase: Phrase, tempo: TempoEstimate?) -> [EmotionScore]
    func spec(for phrase: Phrase, tempo: TempoEstimate?, memoryHints: SessionMemory) -> PhraseSpec
}
