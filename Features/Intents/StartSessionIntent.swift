import AppIntents
import Observation

/// The seam between App Intents (which run outside any view) and SwiftUI navigation:
/// the intent bumps a counter, and `SongListView` — the routing owner — watches it and
/// starts a session. A monotonic counter (not a Bool) so two rapid invocations both fire.
@MainActor
@Observable
final class QuickActions {
    static let shared = QuickActions()

    private(set) var pendingSessionRequests = 0

    func requestSession() {
        pendingSessionRequests += 1
    }
}

/// "Start a session in Song Finisher" — Siri, Shortcuts, and Spotlight entry point.
struct StartSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Writing Session"
    static let description = IntentDescription(
        "Opens Song Finisher, creates a new song, and starts listening for a melody."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActions.shared.requestSession()
        return .result()
    }
}

struct SongFinisherShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartSessionIntent(),
            phrases: [
                "Start a session in \(.applicationName)",
                "Write lyrics with \(.applicationName)",
                "Start listening in \(.applicationName)",
            ],
            shortTitle: "Start Session",
            systemImageName: "music.mic"
        )
    }
}
