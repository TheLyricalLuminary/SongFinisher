import Foundation
import SwiftData
import Domain

public enum SongStoreError: Error, Sendable, Equatable {
    case notFound
}

/// The single writer to the SwiftData store (docs/ARCHITECTURE.md §7, §10 isolation
/// domain #4). `@ModelActor` confines every `ModelContext` touch to this actor, so the
/// rest of the app only ever sees `Sendable` Domain value types. Serialized appends fall
/// out of the actor's isolation for free.
@ModelActor
public actor SongStore: SongStoring {

    // MARK: SongStoring

    public func createSong(title: String) async throws -> Song {
        let now = Date()
        let sd = SDSong(
            id: UUID(),
            title: title,
            createdAt: now,
            updatedAt: now,
            tempoBPM: nil,
            sourceMemoURLString: nil,
            memoryData: try Self.encode(SessionMemory())
        )
        modelContext.insert(sd)
        try modelContext.save()
        return Self.toDomain(sd)
    }

    public func fetchSongs() async throws -> [Song] {
        let descriptor = FetchDescriptor<SDSong>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map(Self.toDomain)
    }

    public func append(line: LyricLine, to songID: UUID) async throws {
        guard let sd = try fetchSD(songID) else { throw SongStoreError.notFound }
        let sdLine = SDLyricLine(
            id: line.id,
            sortIndex: sd.lines.count,
            lineData: try Self.encode(line)
        )
        sdLine.song = sd
        modelContext.insert(sdLine)
        sd.updatedAt = Date()
        try modelContext.save()
    }

    /// Removes one accepted line. Flow mode keeps lines automatically, so taking one
    /// back has to be possible without ending the session — otherwise an automatic keep
    /// would be destructive. Sort indices are re-densified so a later append still lands
    /// at the end.
    public func removeLine(id: UUID, from songID: UUID) async throws {
        guard let sd = try fetchSD(songID) else { throw SongStoreError.notFound }
        guard sd.lines.contains(where: { $0.id == id }) else { return }
        for line in sd.lines where line.id == id {
            modelContext.delete(line)
        }
        let survivors = sd.lines.filter { $0.id != id }.sorted { $0.sortIndex < $1.sortIndex }
        for (index, line) in survivors.enumerated() {
            line.sortIndex = index
        }
        sd.updatedAt = Date()
        try modelContext.save()
    }

    /// Rewrites one line in place. The replacement carries a new `id` (it is a different
    /// `LyricLine`), so the row's identity is updated too while its `sortIndex` — the
    /// line's position in the song — is deliberately preserved.
    public func replaceLine(id: UUID, with line: LyricLine, in songID: UUID) async throws {
        guard let sd = try fetchSD(songID) else { throw SongStoreError.notFound }
        guard let existing = sd.lines.first(where: { $0.id == id }) else { return }
        existing.id = line.id
        existing.lineData = try Self.encode(line)
        sd.updatedAt = Date()
        try modelContext.save()
    }

    public func updateMemory(_ memory: SessionMemory, songID: UUID) async throws {
        guard let sd = try fetchSD(songID) else { throw SongStoreError.notFound }
        sd.memoryData = try Self.encode(memory)
        sd.updatedAt = Date()
        try modelContext.save()
    }

    public func recordRejection(_ rejection: RejectedLine, songID: UUID) async throws {
        guard let sd = try fetchSD(songID) else { throw SongStoreError.notFound }
        var memory = Self.decodeMemory(sd.memoryData)
        memory.rejected.append(rejection)
        // Keep the persisted reject list FIFO-bounded like the in-prompt cap (§9).
        if memory.rejected.count > SessionMemory.maxRejectedInPrompt {
            memory.rejected.removeFirst(memory.rejected.count - SessionMemory.maxRejectedInPrompt)
        }
        sd.memoryData = try Self.encode(memory)
        sd.updatedAt = Date()
        try modelContext.save()
    }

    public func delete(songID: UUID) async throws {
        guard let sd = try fetchSD(songID) else { return }
        modelContext.delete(sd)
        try modelContext.save()
    }

    // MARK: Internals

    private func fetchSD(_ id: UUID) throws -> SDSong? {
        var descriptor = FetchDescriptor<SDSong>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    // Fresh coders per call keeps this Swift-6 clean (JSONEncoder isn't Sendable) and the
    // cost is trivial at a few hundred rows.
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private static func decodeMemory(_ data: Data) -> SessionMemory {
        (try? JSONDecoder().decode(SessionMemory.self, from: data)) ?? SessionMemory()
    }

    private static func toDomain(_ sd: SDSong) -> Song {
        let decoder = JSONDecoder()
        let memory = (try? decoder.decode(SessionMemory.self, from: sd.memoryData)) ?? SessionMemory()
        let lines = sd.lines
            .sorted { $0.sortIndex < $1.sortIndex }
            .compactMap { try? decoder.decode(LyricLine.self, from: $0.lineData) }
        return Song(
            id: sd.id,
            title: sd.title,
            createdAt: sd.createdAt,
            updatedAt: sd.updatedAt,
            lines: lines,
            memory: memory,
            tempoBPM: sd.tempoBPM,
            sourceMemoURL: sd.sourceMemoURLString.flatMap { URL(string: $0) }
        )
    }
}

// MARK: - Container factories

public extension SongStore {
    /// On-disk store for the running app. The caller decides how to react to a throw
    /// (the composition root falls back to an in-memory store so a corrupt file never
    /// hard-crashes launch).
    static func live() throws -> SongStore {
        SongStore(modelContainer: try makeContainer(inMemory: false))
    }

    /// In-memory store for tests, previews, and disk-open fallback.
    static func inMemory() throws -> SongStore {
        SongStore(modelContainer: try makeContainer(inMemory: true))
    }

    static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema([SDSong.self, SDLyricLine.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: config)
    }
}
