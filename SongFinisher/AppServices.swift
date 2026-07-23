import Domain
import MelodyKit
import LyricEngine
import PersistenceKit

/// Composition root: the only place concrete service types are ever named.
/// ViewModels receive protocol existentials from this struct via initializer
/// injection. `.fakes()` mirrors `.live()` for tests and SwiftUI previews.
struct AppServices: Sendable {
    let capture: any AudioCapturing
    let analyzer: any MelodyAnalyzing
    let prosody: any ProsodyDeriving
    let lyrics: any LyricProviding
    /// The unmetered engine: where generation lands when the free tier's daily premium
    /// budget is spent. In `.live()` this is the same `OfflineLyricProvider` instance
    /// that `lyrics` falls back to, so degradation is identical either way.
    let offlineLyrics: any LyricProviding
    let ranker: any CandidateRanking
    let permissions: any PermissionChecking
    let store: any SongStoring

    /// A missing bundled lexicon means the build is broken, not a runtime condition —
    /// `try!` here is deliberate (docs/ARCHITECTURE.md §12 error taxonomy governs
    /// *runtime* failures like mic denial; a corrupt app bundle is a different class
    /// of failure with no graceful UI response).
    static func live() -> AppServices {
        let offline = try! OfflineLyricProvider.bundled()
        return AppServices(
            capture: AudioCaptureService(),
            analyzer: MelodyAnalyzer(),
            prosody: DefaultProsodyDeriver(),
            lyrics: OnDeviceLyricProvider(fallback: offline),
            offlineLyrics: offline,
            ranker: Domain.CandidateRanker(),
            permissions: MicPermissionService(),
            // A corrupt/locked on-disk store must not hard-crash launch: degrade to an
            // in-memory store (this session's songs won't persist, but the app opens).
            store: (try? SongStore.live()) ?? (try! SongStore.inMemory())
        )
    }

    static func fakes(
        capture: any AudioCapturing = FakeAudioCapturing(),
        analyzer: any MelodyAnalyzing = FakeMelodyAnalyzing(),
        prosody: any ProsodyDeriving = DefaultProsodyDeriver(),
        lyrics: any LyricProviding = FakeLyricProvider(),
        offlineLyrics: any LyricProviding = FakeLyricProvider(),
        ranker: any CandidateRanking = Domain.CandidateRanker(),
        permissions: any PermissionChecking = FakePermissionChecking(),
        store: any SongStoring = FakeSongStore()
    ) -> AppServices {
        AppServices(
            capture: capture, analyzer: analyzer, prosody: prosody,
            lyrics: lyrics, offlineLyrics: offlineLyrics, ranker: ranker,
            permissions: permissions, store: store
        )
    }
}
