import Testing
import Foundation
import Domain
@testable import SongFinisher

/// Records the order writes actually land in, and lets the *first* one arrive late.
///
/// That delay is the whole point. `SongStore` serializes each call, but nothing serialized
/// the sequence of them: every write used to go out on its own `Task`, and independent
/// tasks reach an actor in whatever order the scheduler picks. This store makes the
/// scheduler's freedom deterministic so the consequence can be asserted instead of hoped
/// for — it is a stand-in for the first write simply being reached second on a busy device,
/// which is exactly what happens when a writer's phrases arrive faster than the disk.
private actor SlowFirstWriteStore: SongStoring {
    private(set) var removals: [UUID] = []
    /// The line count in each memory snapshot the store was handed, in arrival order.
    private(set) var memorySizes: [Int] = []
    private var firstRemovalPending = true

    func removeLine(id: UUID, from songID: UUID) async throws {
        if firstRemovalPending {
            firstRemovalPending = false
            // Set *before* suspending, so only this call is slowed and a second one is
            // free to overtake it.
            try? await Task.sleep(for: .milliseconds(60))
        }
        removals.append(id)
    }

    func updateMemory(_ memory: SessionMemory, songID: UUID) async throws {
        memorySizes.append(memory.acceptedLines.count)
    }

    func createSong(title: String) async throws -> Song {
        Song(title: title, createdAt: Date(), updatedAt: Date())
    }
    func fetchSongs() async throws -> [Song] { [] }
    func append(line: LyricLine, to songID: UUID) async throws {}
    func recordRejection(_ rejection: RejectedLine, songID: UUID) async throws {}
    func delete(songID: UUID) async throws {}
    func replaceLine(id: UUID, with line: LyricLine, in songID: UUID) async throws {}
}

/// Persistence is fire-and-forget — a failed write never interrupts a live session — but
/// "don't wait for it" is not "don't order it". Every store write goes through one chain
/// in `SessionViewModel`, and these pin why.
///
/// Serialized because `SessionViewModel` reads flow mode from `UserDefaults.standard`.
@Suite(.serialized) @MainActor struct PersistenceOrderingTests {

    private func line(_ text: String) -> LyricLine {
        LyricLine(phraseID: UUID(), text: text, stressMap: StressMap(pattern: [.strong]),
                  emotion: .hope, acceptedAt: Date())
    }

    /// A view model bound to a song, so its writes actually reach the store — every
    /// persistence path short-circuits on a nil `songID`.
    private func viewModel(store: SlowFirstWriteStore,
                           memory: SessionMemory) -> SessionViewModel {
        UserDefaults.standard.removeObject(forKey: "session.flowMode")
        return SessionViewModel(services: .fakes(store: store),
                                songID: UUID(), initialMemory: memory)
    }

    @Test func writesReachTheStoreInTheOrderTheWriterMadeThem() async throws {
        let first = line("the first line")
        let second = line("the second line")
        var memory = SessionMemory()
        memory.acceptedLines = [first, second]
        let store = SlowFirstWriteStore()
        let vm = viewModel(store: store, memory: memory)

        vm.undoLastAccepted()   // takes back "the second line"
        vm.undoLastAccepted()   // then "the first line"

        try await Task.sleep(for: .milliseconds(300))

        #expect(await store.removals == [second.id, first.id],
                "the second undo overtook the first")
        UserDefaults.standard.removeObject(forKey: "session.flowMode")
    }

    @Test func theLastMemorySnapshotWrittenIsTheNewestOne() async throws {
        // Each write carries a `SessionMemory` snapshot taken when it was issued. Out of
        // order, an older task landing last overwrites newer memory with staler memory —
        // and since memory is what a resumed session reads back, the writer reopens the
        // song to find a line they took back sitting there again.
        var memory = SessionMemory()
        memory.acceptedLines = [line("the first line"), line("the second line")]
        let store = SlowFirstWriteStore()
        let vm = viewModel(store: store, memory: memory)

        vm.undoLastAccepted()
        vm.undoLastAccepted()

        try await Task.sleep(for: .milliseconds(300))

        let sizes = await store.memorySizes
        #expect(sizes == [1, 0], "memory snapshots landed out of order: \(sizes)")
        #expect(sizes.last == 0,
                "the store's last word on this song is a line the writer had taken back")
        UserDefaults.standard.removeObject(forKey: "session.flowMode")
    }
}
