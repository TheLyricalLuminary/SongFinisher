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

    /// [More Like This]: re-request anchored to an exemplar line's imagery.
    public func withVariationSeed(_ text: String) -> PhraseSpec {
        PhraseSpec(
            phraseID: phraseID, budget: budget, emotions: emotions,
            tempoBPM: tempoBPM, tempoConfidence: tempoConfidence, contourShape: contourShape,
            noteDurationsMs: noteDurationsMs, longNoteSlots: longNoteSlots, phraseDuration: phraseDuration,
            requestedEmotionOverride: requestedEmotionOverride, variationSeedText: text
        )
    }

    /// [Different Emotion]: re-request with the emotion block replaced.
    public func withEmotionOverride(_ emotion: Emotion) -> PhraseSpec {
        PhraseSpec(
            phraseID: phraseID, budget: budget, emotions: emotions,
            tempoBPM: tempoBPM, tempoConfidence: tempoConfidence, contourShape: contourShape,
            noteDurationsMs: noteDurationsMs, longNoteSlots: longNoteSlots, phraseDuration: phraseDuration,
            requestedEmotionOverride: emotion, variationSeedText: variationSeedText
        )
    }

    /// The "+1 / −1 syllable" escape hatch: re-request against an adjusted exact
    /// target (not a wider tolerance — the user has stated a precise correction).
    public func withAdjustedSyllableTarget(by delta: Int) -> PhraseSpec {
        let newTarget = max(1, budget.target + delta)
        let adjustedBudget = SyllableBudget(target: newTarget, tolerance: budget.tolerance, stressMap: budget.stressMap)
        return PhraseSpec(
            phraseID: phraseID, budget: adjustedBudget, emotions: emotions,
            tempoBPM: tempoBPM, tempoConfidence: tempoConfidence, contourShape: contourShape,
            noteDurationsMs: noteDurationsMs, longNoteSlots: longNoteSlots, phraseDuration: phraseDuration,
            requestedEmotionOverride: requestedEmotionOverride, variationSeedText: variationSeedText
        )
    }
}
