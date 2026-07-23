import Foundation

public enum ProviderKind: String, Sendable, Equatable, Codable {
    case claude, offline, onDevice
}

/// LLM self-reported scores on the two genuinely subjective axes. Never trusted for the
/// objective axes (syllables, stress) — those are always recomputed on-device.
public struct ModelScores: Sendable, Equatable, Codable {
    public let emotionalFit: Double
    public let memorability: Double

    public init(emotionalFit: Double, memorability: Double) {
        self.emotionalFit = min(1, max(0, emotionalFit))
        self.memorability = min(1, max(0, memorability))
    }
}

public struct LyricCandidate: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let phraseID: UUID
    public let text: String
    public let syllableCount: Int
    public let stressAlignment: [Stress]
    public let provider: ProviderKind
    public let repaired: Bool
    public let modelScores: ModelScores?

    public init(
        id: UUID = UUID(),
        phraseID: UUID,
        text: String,
        syllableCount: Int,
        stressAlignment: [Stress],
        provider: ProviderKind,
        repaired: Bool = false,
        modelScores: ModelScores? = nil
    ) {
        self.id = id
        self.phraseID = phraseID
        self.text = text
        self.syllableCount = syllableCount
        self.stressAlignment = stressAlignment
        self.provider = provider
        self.repaired = repaired
        self.modelScores = modelScores
    }
}
