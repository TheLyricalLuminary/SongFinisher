import Foundation

public protocol SongStoring: Sendable {
    func createSong(title: String) async throws -> Song
    func fetchSongs() async throws -> [Song]
    func append(line: LyricLine, to songID: UUID) async throws
    func updateMemory(_ memory: SessionMemory, songID: UUID) async throws
    func recordRejection(_ rejection: RejectedLine, songID: UUID) async throws
    func delete(songID: UUID) async throws
    /// Flow mode's undo: takes back one accepted line without touching the rest.
    func removeLine(id: UUID, from songID: UUID) async throws
    /// Rewrites one line **in place**, keeping its position in the song.
    ///
    /// Needed because lines are kept automatically as they arrive, so regenerating a
    /// phrase produces a replacement for a line already stored. Remove-then-append would
    /// send the rewritten line to the end, and the saved song and its export would then
    /// disagree with the order the writer watched being built.
    func replaceLine(id: UUID, with line: LyricLine, in songID: UUID) async throws
}
