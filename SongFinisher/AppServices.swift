import Domain
import MelodyKit
import LyricEngine
import PersistenceKit
#if canImport(FoundationModels)
import FoundationModels
#endif

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
    let sparks: any SparkProviding
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
            lyrics: bestAvailableLyricProvider(offline: offline),
            offlineLyrics: offline,
            sparks: try! LexiconSparkProvider.bundled(),
            ranker: Domain.CandidateRanker(),
            permissions: MicPermissionService(),
            // A corrupt/locked on-disk store must not hard-crash launch: degrade to an
            // in-memory store (this session's songs won't persist, but the app opens).
            store: (try? SongStore.live()) ?? (try! SongStore.inMemory())
        )
    }

    /// Composition-time provider selection: the on-device Foundation Models provider
    /// on Apple Intelligence hardware, the deterministic offline assembler everywhere
    /// else. Availability is a runtime question (eligible hardware AND Apple
    /// Intelligence enabled AND the model downloaded), so this can't be a build flag.
    /// Takes the already-built offline provider rather than loading the lexicon a
    /// second time — `live()` needs that same instance for `offlineLyrics` anyway.
    private static func bestAvailableLyricProvider(offline: OfflineLyricProvider) -> any LyricProviding {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), FoundationModelsLyricProvider.isModelAvailable {
            return FoundationModelsLyricProvider(fallback: offline)
        }
        #endif
        return offline
    }

    static func fakes(
        capture: any AudioCapturing = FakeAudioCapturing(),
        analyzer: any MelodyAnalyzing = FakeMelodyAnalyzing(),
        prosody: any ProsodyDeriving = DefaultProsodyDeriver(),
        lyrics: any LyricProviding = FakeLyricProvider(),
        offlineLyrics: any LyricProviding = FakeLyricProvider(),
        sparks: any SparkProviding = FakeSparkProviding(),
        ranker: any CandidateRanking = Domain.CandidateRanker(),
        permissions: any PermissionChecking = FakePermissionChecking(),
        store: any SongStoring = FakeSongStore()
    ) -> AppServices {
        AppServices(
            capture: capture, analyzer: analyzer, prosody: prosody,
            lyrics: lyrics, offlineLyrics: offlineLyrics, sparks: sparks,
            ranker: ranker, permissions: permissions, store: store
        )
    }
}
