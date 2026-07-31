import Testing
import Foundation
import Domain
@testable import PersistenceKit

private func makeLine(_ text: String, stress: String = "Sw", emotion: Emotion = .longing) -> LyricLine {
    LyricLine(
        phraseID: UUID(),
        text: text,
        stressMap: StressMap.parse(stress) ?? StressMap(pattern: [.strong]),
        emotion: emotion,
        acceptedAt: Date()
    )
}

@Suite struct SongStoreTests {

    @Test func createThenFetchRoundTrips() async throws {
        let store = try SongStore.inMemory()
        let song = try await store.createSong(title: "Midnight Draft")

        let all = try await store.fetchSongs()
        #expect(all.count == 1)
        #expect(all.first?.id == song.id)
        #expect(all.first?.title == "Midnight Draft")
        #expect(all.first?.lines.isEmpty == true)
    }

    @Test func removeLineDropsItAndRedensifiesOrder() async throws {
        // Flow mode keeps lines without asking, so undo has to actually remove the row —
        // not just the in-memory copy — or the song sheet keeps a line the writer rejected.
        let store = try SongStore.inMemory()
        let song = try await store.createSong(title: "Undo Test")
        let first = makeLine("the first line")
        let second = makeLine("the second line")
        let third = makeLine("the third line")
        for line in [first, second, third] {
            try await store.append(line: line, to: song.id)
        }

        try await store.removeLine(id: second.id, from: song.id)

        let lines = try await store.fetchSongs().first?.lines ?? []
        #expect(lines.map(\.text) == ["the first line", "the third line"])

        // A later append must land at the end, which only holds if sort indices were
        // re-densified after the removal.
        let fourth = makeLine("the fourth line")
        try await store.append(line: fourth, to: song.id)
        let after = try await store.fetchSongs().first?.lines ?? []
        #expect(after.map(\.text) == ["the first line", "the third line", "the fourth line"])
    }

    @Test func removingAnUnknownLineIsANoOp() async throws {
        let store = try SongStore.inMemory()
        let song = try await store.createSong(title: "No-op Test")
        try await store.append(line: makeLine("kept"), to: song.id)

        try await store.removeLine(id: UUID(), from: song.id)

        #expect(try await store.fetchSongs().first?.lines.count == 1)
    }

    @Test func appendedLinesPersistInOrder() async throws {
        let store = try SongStore.inMemory()
        let song = try await store.createSong(title: "Order Test")

        try await store.append(line: makeLine("all the miles between us"), to: song.id)
        try await store.append(line: makeLine("fade to something less"), to: song.id)
        try await store.append(line: makeLine("and i drive on anyway"), to: song.id)

        let fetched = try #require(try await store.fetchSongs().first)
        #expect(fetched.lines.map(\.text) == [
            "all the miles between us",
            "fade to something less",
            "and i drive on anyway",
        ])
    }

    @Test func memoryBlobRoundTrips() async throws {
        let store = try SongStore.inMemory()
        let song = try await store.createSong(title: "Memory Test")

        var memory = SessionMemory()
        memory.themes = ["distance", "driving"]
        memory.dominantEmotion = .melancholy
        memory.hookLine = "and i drive on anyway"
        try await store.updateMemory(memory, songID: song.id)

        let fetched = try #require(try await store.fetchSongs().first)
        #expect(fetched.memory.themes == ["distance", "driving"])
        #expect(fetched.memory.dominantEmotion == .melancholy)
        #expect(fetched.memory.hookLine == "and i drive on anyway")
    }

    @Test func recordRejectionAppendsAndCaps() async throws {
        let store = try SongStore.inMemory()
        let song = try await store.createSong(title: "Reject Test")

        for i in 0..<(SessionMemory.maxRejectedInPrompt + 5) {
            try await store.recordRejection(RejectedLine(text: "reject \(i)", reason: .regenerated), songID: song.id)
        }

        let fetched = try #require(try await store.fetchSongs().first)
        #expect(fetched.memory.rejected.count == SessionMemory.maxRejectedInPrompt)
        // FIFO: the oldest rejections dropped, newest retained.
        #expect(fetched.memory.rejected.last?.text == "reject \(SessionMemory.maxRejectedInPrompt + 4)")
    }

    @Test func deleteRemovesSongAndCascadesLines() async throws {
        let store = try SongStore.inMemory()
        let song = try await store.createSong(title: "Delete Test")
        try await store.append(line: makeLine("a line to cascade"), to: song.id)

        try await store.delete(songID: song.id)
        #expect(try await store.fetchSongs().isEmpty)
    }

    @Test func appendToMissingSongThrowsNotFound() async throws {
        let store = try SongStore.inMemory()
        await #expect(throws: SongStoreError.notFound) {
            try await store.append(line: makeLine("orphan"), to: UUID())
        }
    }

    @Test func fetchSortsMostRecentlyUpdatedFirst() async throws {
        let store = try SongStore.inMemory()
        let first = try await store.createSong(title: "First")
        _ = try await store.createSong(title: "Second")

        // Touch `first` last so it should sort ahead of `second`.
        try await store.append(line: makeLine("bump update"), to: first.id)

        let titles = try await store.fetchSongs().map(\.title)
        #expect(titles.first == "First")
        #expect(titles.contains("Second"))
    }
}
