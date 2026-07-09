import Foundation

/// One analysis-rate sample of the pitch tracker (see docs/ARCHITECTURE.md §8, 10 ms hop).
public struct PitchFrame: Sendable, Equatable, Codable {
    public let time: TimeInterval
    public let frequencyHz: Double?
    public let midiNote: Double?
    public let rmsEnergy: Float
    public let confidence: Float

    public init(time: TimeInterval, frequencyHz: Double?, midiNote: Double?, rmsEnergy: Float, confidence: Float) {
        self.time = time
        self.frequencyHz = frequencyHz
        self.midiNote = midiNote
        self.rmsEnergy = rmsEnergy
        self.confidence = confidence
    }

    public var isVoiced: Bool { frequencyHz != nil }
}
