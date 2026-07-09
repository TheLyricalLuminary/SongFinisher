import Foundation

/// The single value handed to the AI layer for one phrase — also the fixture-golden
/// format used by DSP tests (docs/ARCHITECTURE.md §4, §8).
public struct PhraseSpec: Sendable, Equatable, Codable {
    public let phraseID: UUID
    public let budget: SyllableBudget
    public let emotions: [EmotionScore]
    public let tempoBPM: Double
    public let tempoConfidence: Float
    public let contourShape: ContourShape
    public let noteDurationsMs: [Int]
    public let longNoteSlots: [Int]
    public let phraseDuration: TimeInterval
    public let requestedEmotionOverride: Emotion?
    public let variationSeedText: String?

    public init(
        phraseID: UUID,
        budget: SyllableBudget,
        emotions: [EmotionScore],
        tempoBPM: Double,
        tempoConfidence: Float,
        contourShape: ContourShape,
        noteDurationsMs: [Int],
        longNoteSlots: [Int],
        phraseDuration: TimeInterval,
        requestedEmotionOverride: Emotion? = nil,
        variationSeedText: String? = nil
    ) {
        self.phraseID = phraseID
        self.budget = budget
        self.emotions = emotions
        self.tempoBPM = tempoBPM
        self.tempoConfidence = tempoConfidence
        self.contourShape = contourShape
        self.noteDurationsMs = noteDurationsMs
        self.longNoteSlots = longNoteSlots
        self.phraseDuration = phraseDuration
        self.requestedEmotionOverride = requestedEmotionOverride
        self.variationSeedText = variationSeedText
    }

    /// Top-3 emotions, sorted, as sent to the AI layer.
    public var topEmotions: [EmotionScore] { Array(emotions.sortedByConfidence().prefix(3)) }
}
