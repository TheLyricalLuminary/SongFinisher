import Foundation

public struct TempoEstimate: Sendable, Equatable, Codable {
    public let bpm: Double
    public let confidence: Float
    public let beatPhase: TimeInterval

    public init(bpm: Double, confidence: Float, beatPhase: TimeInterval) {
        self.bpm = bpm
        self.confidence = confidence
        self.beatPhase = beatPhase
    }

    /// Below this confidence the stress mapper drops the beat grid (docs/ARCHITECTURE.md §8).
    public static let reliableConfidenceThreshold: Float = 0.35

    public var isReliable: Bool { confidence >= Self.reliableConfidenceThreshold }

    /// Seconds per beat.
    public var beatPeriod: TimeInterval { 60.0 / bpm }
}
