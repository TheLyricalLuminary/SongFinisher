import Foundation

/// Which engine wrote a line. Every case runs on the device — there is deliberately
/// no remote case, because "audio never leaves the device" is an architectural fact
/// here, not a policy promise. A future bundled-model tier (a quantized open-weights
/// model for hardware without Apple Intelligence) would be a new on-device case
/// behind the same seam.
public enum ProviderKind: String, Sendable, Equatable, Codable {
    /// Apple's on-device Foundation Models framework — the premium path on
    /// Apple Intelligence hardware.
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
