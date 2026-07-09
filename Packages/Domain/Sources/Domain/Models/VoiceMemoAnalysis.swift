import Foundation

public struct MemoSection: Sendable, Equatable, Codable {
    public let label: String
    public let phraseIDs: [UUID]

    public init(label: String, phraseIDs: [UUID]) {
        self.label = label
        self.phraseIDs = phraseIDs
    }
}

/// Output of the Voice Memo Resurrection pipeline (docs/ARCHITECTURE.md §9).
public struct VoiceMemoAnalysis: Sendable, Equatable, Codable {
    public let duration: TimeInterval
    public let tempo: TempoEstimate
    public let phrases: [Phrase]
    public let specs: [PhraseSpec]
    public let sections: [MemoSection]
    public let repeatedPhraseGroups: [[UUID]]
    public let dominantEmotions: [EmotionScore]

    public init(
        duration: TimeInterval,
        tempo: TempoEstimate,
        phrases: [Phrase],
        specs: [PhraseSpec],
        sections: [MemoSection],
        repeatedPhraseGroups: [[UUID]],
        dominantEmotions: [EmotionScore]
    ) {
        self.duration = duration
        self.tempo = tempo
        self.phrases = phrases
        self.specs = specs
        self.sections = sections
        self.repeatedPhraseGroups = repeatedPhraseGroups
        self.dominantEmotions = dominantEmotions
    }

    /// The most-repeated, highest-energy phrase group — the hook candidate.
    public var hookGroup: [UUID]? {
        repeatedPhraseGroups.max(by: { $0.count < $1.count })
    }
}
