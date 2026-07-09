import Foundation

/// A segmented note within a phrase, produced by the note segmenter.
public struct NoteEvent: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let onset: TimeInterval
    public let duration: TimeInterval
    public let midiNote: Double
    public let peakEnergy: Float
    public let beatStrength: Float
    public let isMelisma: Bool

    public init(
        id: UUID = UUID(),
        onset: TimeInterval,
        duration: TimeInterval,
        midiNote: Double,
        peakEnergy: Float,
        beatStrength: Float,
        isMelisma: Bool = false
    ) {
        self.id = id
        self.onset = onset
        self.duration = duration
        self.midiNote = midiNote
        self.peakEnergy = peakEnergy
        self.beatStrength = beatStrength
        self.isMelisma = isMelisma
    }

    public var end: TimeInterval { onset + duration }
}
