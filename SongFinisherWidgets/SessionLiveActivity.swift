import ActivityKit
import WidgetKit
import SwiftUI

/// The listening session on the lock screen and in the Dynamic Island: what phase the
/// session is in, which song it's writing into, and the last line accepted. Background
/// audio keeps the session alive while the phone is locked, so this is a live view of
/// real work — not a static banner.
struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color(red: 0.051, green: 0.059, blue: 0.102))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.phase.label, systemImage: context.state.phase.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(lineCountLabel(context.state.acceptedLineCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.songTitle)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                        if let last = context.state.lastAcceptedLine {
                            Text("“\(last)”")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.phase.systemImage)
                    .foregroundStyle(Color(red: 0.51, green: 0.58, blue: 0.78))
            } compactTrailing: {
                Text("\(context.state.acceptedLineCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            } minimal: {
                Image(systemName: "waveform")
                    .foregroundStyle(Color(red: 0.51, green: 0.58, blue: 0.78))
            }
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<SessionActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: context.state.phase.systemImage)
                .font(.title2)
                .foregroundStyle(Color(red: 0.51, green: 0.58, blue: 0.78))
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(context.state.phase.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(lineCountLabel(context.state.acceptedLineCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(context.attributes.songTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let last = context.state.lastAcceptedLine {
                    Text("“\(last)”")
                        .font(.caption.italic())
                        .foregroundStyle(Color(red: 0.51, green: 0.58, blue: 0.78))
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
    }
}

private func lineCountLabel(_ count: Int) -> String {
    count == 1 ? "1 line" : "\(count) lines"
}
