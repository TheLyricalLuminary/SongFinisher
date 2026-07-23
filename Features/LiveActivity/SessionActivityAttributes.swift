import Foundation
// ActivityKit exists on macOS (canImport succeeds) but its types are all marked
// unavailable there — the os(iOS) leg of the guard is what actually matters.
#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// The Live Activity contract shared between the app and the SongFinisherWidgets
/// extension (this file is compiled into both targets — keep it Foundation-only apart
/// from ActivityKit itself). One activity = one listening session: the lock screen /
/// Dynamic Island shows what the session is doing and how much has been written.
struct SessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case listening, analyzing, suggesting

            var label: String {
                switch self {
                case .listening: "Listening"
                case .analyzing: "Analyzing"
                case .suggesting: "Lines ready"
                }
            }

            var systemImage: String {
                switch self {
                case .listening: "waveform"
                case .analyzing: "waveform.badge.magnifyingglass"
                case .suggesting: "text.quote"
                }
            }
        }

        var phase: Phase
        var acceptedLineCount: Int
        var lastAcceptedLine: String?
    }

    var songTitle: String
}
#endif
