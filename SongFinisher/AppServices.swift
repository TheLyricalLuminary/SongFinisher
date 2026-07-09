import Domain
import MelodyKit
import LyricEngine
import PersistenceKit

/// Composition root: the only place concrete service types are ever named.
/// ViewModels receive protocol existentials from this struct via initializer
/// injection. `.fakes()` mirrors `.live()` for tests and SwiftUI previews.
struct AppServices: Sendable {
    // Service protocols are added here as they land (docs/ARCHITECTURE.md §5):
    // let capture: any AudioCapturing
    // let analyzer: any MelodyAnalyzing
    // let prosody: any ProsodyDeriving
    // let lyrics: any LyricProviding
    // let ranker: any CandidateRanking
    // let store: any SongStoring
    // let permissions: any PermissionChecking

    static func live() -> AppServices {
        AppServices()
    }

    static func fakes() -> AppServices {
        AppServices()
    }
}
