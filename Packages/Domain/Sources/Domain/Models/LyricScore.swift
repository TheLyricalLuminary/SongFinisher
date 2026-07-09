import Foundation

/// Fixed ranking weights (docs/ARCHITECTURE.md §9). Objective axes (syllable, stress,
/// singability, continuity) carry 70% of the total; the model is never the judge of
/// objective constraints.
public struct LyricScore: Sendable, Equatable, Codable {
    public let syllableFit: Double
    public let stressFit: Double
    public let singability: Double
    public let emotionalFit: Double
    public let continuity: Double
    public let memorability: Double

    public init(
        syllableFit: Double,
        stressFit: Double,
        singability: Double,
        emotionalFit: Double,
        continuity: Double,
        memorability: Double
    ) {
        self.syllableFit = syllableFit
        self.stressFit = stressFit
        self.singability = singability
        self.emotionalFit = emotionalFit
        self.continuity = continuity
        self.memorability = memorability
    }

    public static let syllableWeight = 0.30
    public static let stressWeight = 0.25
    public static let singabilityWeight = 0.15
    public static let emotionalFitWeight = 0.15
    public static let continuityWeight = 0.10
    public static let memorabilityWeight = 0.05

    public var total: Double {
        Self.syllableWeight * syllableFit
            + Self.stressWeight * stressFit
            + Self.singabilityWeight * singability
            + Self.emotionalFitWeight * emotionalFit
            + Self.continuityWeight * continuity
            + Self.memorabilityWeight * memorability
    }
}

public struct RankedCandidate: Sendable, Equatable, Identifiable {
    public let candidate: LyricCandidate
    public let score: LyricScore

    public init(candidate: LyricCandidate, score: LyricScore) {
        self.candidate = candidate
        self.score = score
    }

    public var id: UUID { candidate.id }
}
