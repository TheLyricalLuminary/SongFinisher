import Foundation
import SwiftData

// SwiftData @Model classes are quarantined inside PersistenceKit (docs/ARCHITECTURE.md §7):
// they never cross a package boundary. The store maps them to/from Domain value types.
//
// Design choice: high-churn, deeply-nested Domain values (the full `LyricLine` — which
// carries a `StressMap` of enum arrays — and the whole `SessionMemory`) are stored as
// schema-versioned Codable JSON `Data` blobs rather than exploded into SwiftData columns.
// This sidesteps SwiftData's awkward handling of nested arrays/enums and means prompt-shape
// evolution costs zero migrations. Lines remain *real entities* (individually appendable,
// cascade-deletable, order-preserving via `sortIndex`) as the architecture requires.

@Model
final class SDSong {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var tempoBPM: Double?
    var sourceMemoURLString: String?
    /// Encoded `SessionMemory` (read/written whole — see §7 "memory as blob").
    var memoryData: Data
    @Relationship(deleteRule: .cascade, inverse: \SDLyricLine.song)
    var lines: [SDLyricLine]

    init(
        id: UUID,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        tempoBPM: Double?,
        sourceMemoURLString: String?,
        memoryData: Data
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tempoBPM = tempoBPM
        self.sourceMemoURLString = sourceMemoURLString
        self.memoryData = memoryData
        self.lines = []
    }
}

@Model
final class SDLyricLine {
    @Attribute(.unique) var id: UUID
    /// Preserves accepted order; SwiftData relationships are otherwise unordered.
    var sortIndex: Int
    /// Encoded Domain `LyricLine`.
    var lineData: Data
    var song: SDSong?

    init(id: UUID, sortIndex: Int, lineData: Data) {
        self.id = id
        self.sortIndex = sortIndex
        self.lineData = lineData
    }
}
