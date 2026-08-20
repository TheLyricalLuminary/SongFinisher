import Foundation
import Domain

/// The library home's brain (docs/ARCHITECTURE.md §6 "SongListView shell"): owns the list
/// of saved songs and the create/delete intents. Reads flow through the same `SongStoring`
/// existential the session writes to, so the library reflects accepted lines as soon as a
/// session persists them.
@MainActor
@Observable
final class SongListViewModel {
    private(set) var songs: [Song] = []
    private(set) var loadError: String?

    private let store: any SongStoring

    init(store: any SongStoring) {
        self.store = store
    }

    /// Best-effort refresh. A read failure surfaces a banner but leaves the last-known
    /// list in place — a transient store error shouldn't blank the user's library.
    func load() async {
        do {
            songs = try await store.fetchSongs()
            loadError = nil
        } catch {
            loadError = "Couldn't load your songs. \(error.localizedDescription)"
        }
    }

    /// Creates a song and optimistically inserts it at the front (fetch order is
    /// most-recently-updated-first, and a brand-new song is the most recent). Returns the
    /// created song so the caller can immediately route into a session for it.
    @discardableResult
    func createSong(title: String) async -> Song? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmed.isEmpty ? Self.defaultTitle() : trimmed
        do {
            let song = try await store.createSong(title: finalTitle)
            songs.insert(song, at: 0)
            loadError = nil
            return song
        } catch {
            loadError = "Couldn't create the song. \(error.localizedDescription)"
            return nil
        }
    }

    func delete(_ song: Song) async {
        // Optimistic removal keeps the list snappy; on failure we reload to resync.
        let previous = songs
        songs.removeAll { $0.id == song.id }
        do {
            try await store.delete(songID: song.id)
        } catch {
            loadError = "Couldn't delete “\(song.title).” \(error.localizedDescription)"
            songs = previous
        }
    }

    func delete(at offsets: IndexSet) async {
        let targets = offsets.map { songs[$0] }
        for song in targets {
            await delete(song)
        }
    }

    /// The freshest snapshot of a song by id — SongSheet/Session route by id, and the
    /// stored copy may have advanced past what a captured `Song` value held.
    func song(_ id: UUID) -> Song? {
        songs.first { $0.id == id }
    }

    private static func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Untitled — \(formatter.string(from: Date()))"
    }
}
