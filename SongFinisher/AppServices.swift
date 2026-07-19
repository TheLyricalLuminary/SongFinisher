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
    let sparks: any SparkProviding
    let ranker: any CandidateRanking
    let permissions: any PermissionChecking

    /// A missing bundled lexicon means the build is broken, not a runtime condition —
    /// `try!` here is deliberate (docs/ARCHITECTURE.md §12 error taxonomy governs
    /// *runtime* failures like mic denial; a corrupt app bundle is a different class
    /// of failure with no graceful UI response).
    static func live() -> AppServices {
        AppServices(
            capture: AudioCaptureService(),
            analyzer: MelodyAnalyzer(),
            prosody: DefaultProsodyDeriver(),
            lyrics: bestAvailableLyricProvider(),
            sparks: try! LexiconSparkProvider.bundled(),
            ranker: Domain.CandidateRanker(),
            permissions: MicPermissionService()
        )
    }

    /// Composition-time provider selection: the on-device Foundation Models provider
    /// on Apple Intelligence hardware, the deterministic offline assembler everywhere
    /// else. Availability is a runtime question (eligible hardware AND Apple
    /// Intelligence enabled AND the model downloaded), so this can't be a build flag.
    private static func bestAvailableLyricProvider() -> any LyricProviding {
        let offline = try! OfflineLyricProvider.bundled()
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
        sparks: any SparkProviding = FakeSparkProviding(),
        ranker: any CandidateRanking = Domain.CandidateRanker(),
        permissions: any PermissionChecking = FakePermissionChecking()
    ) -> AppServices {
        AppServices(
            capture: capture, analyzer: analyzer, prosody: prosody,
            lyrics: lyrics, sparks: sparks, ranker: ranker, permissions: permissions
        )
    }
}
