import Foundation

/// Every generator the app can run. Both are on-device by construction: there is no
/// remote case, and no networking anywhere in the app or its packages, which is what
/// lets `site/privacy.html` state that audio never leaves the device as a fact about
/// the architecture rather than a promise about conduct.
public enum ProviderKind: String, Sendable, Equatable, Codable {
    /// Apple's on-device Foundation Models framework — the premium path on
    /// Apple Intelligence hardware. Nothing leaves the device.
    case appleIntelligence
    /// The deterministic lexicon assembler — the universal fallback.
    case offline
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
