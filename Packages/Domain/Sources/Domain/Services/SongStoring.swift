import Foundation

public protocol SongStoring: Sendable {
    func createSong(title: String) async throws -> Song
    func fetchSongs() async throws -> [Song]
    func append(line: LyricLine, to songID: UUID) async throws
    func updateMemory(_ memory: SessionMemory, songID: UUID) async throws
    func recordRejection(_ rejection: RejectedLine, songID: UUID) async throws
    func delete(songID: UUID) async throws
}
