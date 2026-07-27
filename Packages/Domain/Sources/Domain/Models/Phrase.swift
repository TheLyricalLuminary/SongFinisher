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
    /// True when the phrase came from the polyphonic (strummed-chord) fallback: notes
    /// are onset/ring-out events whose `midiNote` is a defaulted placeholder, so every
    /// pitch-derived quantity (contour, intervals, stress-from-pitch) must be skipped
    /// and the spec built from rhythm alone.
    public let isRhythmOnly: Bool

    public init(
        id: UUID = UUID(),
        index: Int,
        start: TimeInterval,
        end: TimeInterval,
        notes: [NoteEvent],
        endsWithCadence: Bool,
        pitchConfidence: Double,
        isRhythmOnly: Bool = false
    ) {
        self.id = id
        self.index = index
        self.start = start
        self.end = end
        self.notes = notes
        self.endsWithCadence = endsWithCadence
        self.pitchConfidence = pitchConfidence
        self.isRhythmOnly = isRhythmOnly
    }

    /// Memo analyses are cached as Codable JSON keyed by file hash; payloads written
    /// before `isRhythmOnly` existed must keep decoding (as melodic phrases).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.index = try container.decode(Int.self, forKey: .index)
        self.start = try container.decode(TimeInterval.self, forKey: .start)
        self.end = try container.decode(TimeInterval.self, forKey: .end)
        self.notes = try container.decode([NoteEvent].self, forKey: .notes)
        self.endsWithCadence = try container.decode(Bool.self, forKey: .endsWithCadence)
        self.pitchConfidence = try container.decode(Double.self, forKey: .pitchConfidence)
        self.isRhythmOnly = try container.decodeIfPresent(Bool.self, forKey: .isRhythmOnly) ?? false
    }

    public var duration: TimeInterval { end - start }

    /// Notes after melisma merge: each melisma note is folded into the syllable slot
    /// of the note it glides from, so it never earns its own slot.
    public var syllableBearingNotes: [NoteEvent] { notes.filter { !$0.isMelisma } }
}
