import Foundation

/// A segmented musical phrase: a run of notes bounded by silence, cadence, or a timeout.
public struct Phrase: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let index: Int
    public let start: TimeInterval
    public let end: TimeInterval
    public let notes: [NoteEvent]
    public let endsWithCadence: Bool
    public let pitchConfidence: Double

    public init(
        id: UUID = UUID(),
        index: Int,
        start: TimeInterval,
        end: TimeInterval,
        notes: [NoteEvent],
        endsWithCadence: Bool,
        pitchConfidence: Double
    ) {
        self.id = id
        self.index = index
        self.start = start
        self.end = end
        self.notes = notes
        self.endsWithCadence = endsWithCadence
        self.pitchConfidence = pitchConfidence
    }

    public var duration: TimeInterval { end - start }

    /// Notes after melisma merge: each melisma note is folded into the syllable slot
    /// of the note it glides from, so it never earns its own slot.
    public var syllableBearingNotes: [NoteEvent] { notes.filter { !$0.isMelisma } }
}
