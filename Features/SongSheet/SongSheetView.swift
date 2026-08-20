import SwiftUI
import Domain

/// The finished-lyrics view (docs/ARCHITECTURE.md §15 build plan item 6): reads a song's
/// accepted lines top to bottom, lets the writer jump back into a session to keep going,
/// and exports the words as plain text via the system share sheet.
struct SongSheetView: View {
    let song: Song?
    let onContinueWriting: () -> Void

    var body: some View {
        Group {
            if let song {
                sheet(for: song)
            } else {
                // The song was deleted (or never resolved) while this route was on the
                // stack — degrade to a clear message rather than a blank screen.
                ContentUnavailableView(
                    "Song Unavailable",
                    systemImage: "questionmark.folder",
                    description: Text("This song may have been deleted.")
                )
            }
        }
    }

    @ViewBuilder
    private func sheet(for song: Song) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary(for: song)

                if song.lines.isEmpty {
                    ContentUnavailableView {
                        Label("No Lines Yet", systemImage: "text.badge.plus")
                    } description: {
                        Text("Continue writing to sing or play a phrase and add your first line.")
                    } actions: {
                        Button("Continue Writing") { onContinueWriting() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                } else {
                    ForEach(song.lines) { line in
                        LineRow(line: line, isHook: isHook(line, in: song))
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(song.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: exportText(for: song)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share lyrics")
                .disabled(song.lines.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onContinueWriting()
                } label: {
                    Image(systemName: "mic.badge.plus")
                }
                .accessibilityLabel("Continue writing")
            }
        }
    }

    @ViewBuilder
    private func summary(for song: Song) -> some View {
        HStack(spacing: 12) {
            if let emotion = song.memory.dominantEmotion {
                Label(emotion.rawValue.capitalized, systemImage: "theatermasks.fill")
            }
            if let bpm = song.tempoBPM {
                Label("\(Int(bpm.rounded())) BPM", systemImage: "metronome.fill")
            }
            Label(lineCountLabel(song), systemImage: "text.alignleft")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }

    private func lineCountLabel(_ song: Song) -> String {
        song.lines.count == 1 ? "1 line" : "\(song.lines.count) lines"
    }

    /// A line is treated as the hook if the model flagged it, or if it's the memory's
    /// designated hook line — either way it's the emotional anchor worth surfacing.
    private func isHook(_ line: LyricLine, in song: Song) -> Bool {
        line.isHookCandidate || (song.memory.hookLine.map { $0 == line.text } ?? false)
    }

    /// Plain-text export: title, a blank line, then the lyrics in order. Deliberately
    /// format-free so it pastes cleanly into Notes, Messages, a DAW comment, anywhere.
    private func exportText(for song: Song) -> String {
        let body = song.lines.map(\.text).joined(separator: "\n")
        return "\(song.title)\n\n\(body)"
    }
}

private struct LineRow: View {
    let line: LyricLine
    let isHook: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if isHook {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
            Text(line.text)
                .font(isHook ? .body.weight(.semibold) : .body)
                .foregroundStyle(isHook ? .primary : .secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, isHook ? 12 : 0)
        .background(
            isHook ? AnyShapeStyle(Color.accentColor.opacity(0.10)) : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}

#Preview("With Lines") {
    NavigationStack {
        SongSheetView(
            song: Song(
                title: "Midnight Draft",
                createdAt: Date(),
                updatedAt: Date(),
                lines: [
                    LyricLine(phraseID: UUID(), text: "all the miles between us", stressMap: StressMap(pattern: [.strong, .weak]), emotion: .longing, acceptedAt: Date(), isHookCandidate: true),
                    LyricLine(phraseID: UUID(), text: "fade to something less", stressMap: StressMap(pattern: [.strong, .weak]), emotion: .melancholy, acceptedAt: Date()),
                    LyricLine(phraseID: UUID(), text: "and i drive on anyway", stressMap: StressMap(pattern: [.strong, .weak]), emotion: .reflection, acceptedAt: Date()),
                ],
                tempoBPM: 92
            ),
            onContinueWriting: {}
        )
    }
}

#Preview("Empty") {
    NavigationStack {
        SongSheetView(
            song: Song(title: "Blank Page", createdAt: Date(), updatedAt: Date()),
            onContinueWriting: {}
        )
    }
}
