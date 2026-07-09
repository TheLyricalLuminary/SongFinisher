import Foundation

public enum Emotion: String, Sendable, Equatable, Codable, CaseIterable {
    case longing, joy, nostalgia, reflection, tension, release, hope, melancholy
}

public struct EmotionScore: Sendable, Equatable, Codable {
    public let emotion: Emotion
    public let confidence: Float

    public init(emotion: Emotion, confidence: Float) {
        self.emotion = emotion
        self.confidence = confidence
    }
}

public extension Sequence where Element == EmotionScore {
    /// Sorted descending by confidence, as sent to the AI layer (top-3 in `PhraseSpec`).
    func sortedByConfidence() -> [EmotionScore] { sorted { $0.confidence > $1.confidence } }
}
