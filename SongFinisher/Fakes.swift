import Foundation
import Domain

/// Test/preview doubles for `AppServices.fakes()`. Never used in `.live()`.

struct FakeAudioCapturing: AudioCapturing {
    var state: AsyncStream<CaptureState> { AsyncStream { $0.yield(.idle) } }
    func start() async throws(CaptureError) -> AsyncStream<AudioChunk> { AsyncStream { $0.finish() } }
    func stop() async {}
}

struct FakeMelodyAnalyzing: MelodyAnalyzing {
    func analyze(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<AnalysisEvent> {
        AsyncStream { $0.finish() }
    }
    func analyzeFile(at url: URL, progress: @Sendable (Double) -> Void) async throws -> VoiceMemoAnalysis {
        VoiceMemoAnalysis(duration: 0, tempo: TempoEstimate(bpm: 0, confidence: 0, beatPhase: 0), phrases: [], specs: [], sections: [], repeatedPhraseGroups: [], dominantEmotions: [])
    }
}

struct FakeLyricProvider: LyricProviding {
    var kind: ProviderKind { .offline }
    func candidates(for spec: PhraseSpec, memory: SessionMemory) async throws(LyricProviderError) -> [LyricCandidate] {
        [LyricCandidate(phraseID: spec.phraseID, text: "placeholder line", syllableCount: spec.budget.target, stressAlignment: spec.budget.stressMap.pattern, provider: .offline)]
    }
}

struct FakePermissionChecking: PermissionChecking {
    func currentMicPermission() async -> MicPermission { .granted }
    func requestMicPermission() async -> MicPermission { .granted }
}

/// In-memory `SongStoring` for previews and ViewModel tests — no SwiftData, fully
/// deterministic. Seed it with songs for previews via `init(seed:)`.
actor FakeSongStore: SongStoring {
    private var songs: [UUID: Song]

    init(seed: [Song] = []) {
        songs = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
    }

    func createSong(title: String) async throws -> Song {
        let now = Date()
        let song = Song(title: title, createdAt: now, updatedAt: now)
        songs[song.id] = song
        return song
    }

    func fetchSongs() async throws -> [Song] {
        songs.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func append(line: LyricLine, to songID: UUID) async throws {
        guard var song = songs[songID] else { throw FakeStoreError.notFound }
        song.lines.append(line)
        song.updatedAt = Date()
        songs[songID] = song
    }

    func updateMemory(_ memory: SessionMemory, songID: UUID) async throws {
        guard var song = songs[songID] else { throw FakeStoreError.notFound }
        song.memory = memory
        song.updatedAt = Date()
        songs[songID] = song
    }

    func recordRejection(_ rejection: RejectedLine, songID: UUID) async throws {
        guard var song = songs[songID] else { throw FakeStoreError.notFound }
        song.memory.rejected.append(rejection)
        songs[songID] = song
    }

    func delete(songID: UUID) async throws {
        songs[songID] = nil
    }

    func removeLine(id: UUID, from songID: UUID) async throws {
        guard var song = songs[songID] else { throw FakeStoreError.notFound }
        song.lines.removeAll { $0.id == id }
        song.updatedAt = Date()
        songs[songID] = song
    }

    enum FakeStoreError: Error { case notFound }
}

struct FakeSparkProviding: SparkProviding {
    func sparks(for spec: PhraseSpec, memory: SessionMemory) -> WordSparks {
        WordSparks(images: ["ember", "hollow", "drifting", "unspoken"], rhymes: ["flame", "name", "same"])
    }
}
