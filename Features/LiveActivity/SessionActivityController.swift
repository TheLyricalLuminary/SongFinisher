import Foundation

/// Platform-neutral session phase the ViewModel reports — mapped to the ActivityKit
/// content state inside the controller so call sites compile identically on the macOS
/// validation target (which has no ActivityKit).
enum SessionActivityPhase {
    case listening, analyzing, suggesting
}

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// Owns the one Live Activity a listening session runs (docs/ARCHITECTURE.md §6 companion:
/// background listening keeps capturing when the phone locks, and this is what the lock
/// screen / Dynamic Island shows meanwhile). Purely local — no push token; the app updates
/// its own activity while the audio background mode keeps it alive.
@MainActor
final class SessionActivityController {
    private var activity: Activity<SessionActivityAttributes>?

    func start(songTitle: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // A stale activity from a previous session that didn't wind down cleanly would
        // leave two cards on the lock screen — end anything of ours first.
        end()
        let initial = SessionActivityAttributes.ContentState(phase: .listening, acceptedLineCount: 0, lastAcceptedLine: nil)
        activity = try? Activity.request(
            attributes: SessionActivityAttributes(songTitle: songTitle),
            content: ActivityContent(state: initial, staleDate: nil)
        )
    }

    func update(phase: SessionActivityPhase, acceptedLineCount: Int, lastAcceptedLine: String?) {
        guard let activity else { return }
        let state = SessionActivityAttributes.ContentState(
            phase: Self.contentPhase(for: phase),
            acceptedLineCount: acceptedLineCount,
            lastAcceptedLine: lastAcceptedLine
        )
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        // Sweep every activity for our attributes type, not just the one this controller
        // started — covers activities orphaned by a crash or force-quit.
        for orphan in Activity<SessionActivityAttributes>.activities {
            let finalState = orphan.content.state
            Task { await orphan.end(ActivityContent(state: finalState, staleDate: nil), dismissalPolicy: .immediate) }
        }
        activity = nil
    }

    private static func contentPhase(for phase: SessionActivityPhase) -> SessionActivityAttributes.ContentState.Phase {
        switch phase {
        case .listening: .listening
        case .analyzing: .analyzing
        case .suggesting: .suggesting
        }
    }
}

#else

/// No-op stand-in for platforms without ActivityKit so `SessionViewModel` can call the
/// same API unconditionally.
@MainActor
final class SessionActivityController {
    func start(songTitle: String) {}
    func update(phase: SessionActivityPhase, acceptedLineCount: Int, lastAcceptedLine: String?) {}
    func end() {}
}

#endif
