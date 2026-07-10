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
            lyrics: try! OfflineLyricProvider.bundled(),
            ranker: Domain.CandidateRanker(),
            permissions: MicPermissionService()
        )
    }

    static func fakes(
        capture: any AudioCapturing = FakeAudioCapturing(),
        analyzer: any MelodyAnalyzing = FakeMelodyAnalyzing(),
        prosody: any ProsodyDeriving = DefaultProsodyDeriver(),
        lyrics: any LyricProviding = FakeLyricProvider(),
        ranker: any CandidateRanking = Domain.CandidateRanker(),
        permissions: any PermissionChecking = FakePermissionChecking()
    ) -> AppServices {
        AppServices(
            capture: capture, analyzer: analyzer, prosody: prosody,
            lyrics: lyrics, ranker: ranker, permissions: permissions
        )
    }
}
