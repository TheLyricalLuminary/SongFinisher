import SwiftUI
import Domain

/// The top-ranked candidate, swipeable to rank 2–3, with the per-syllable stress
/// underline, provider badge, and the four intent controls from docs/ARCHITECTURE.md §9.
struct SuggestionCardView: View {
    let ranked: [RankedCandidate]
    let onUse: (RankedCandidate) -> Void
    let onMoreLikeThis: (RankedCandidate) -> Void
    let onRegenerate: () -> Void
    let onDifferentEmotion: (Emotion) -> Void
    let onAdjustSyllables: (Int) -> Void

    @State private var selection = 0

    /// TabView's `.page` style isn't available on plain macOS (only iOS/Catalyst), so the
    /// rank 2–3 carousel is a plain drag gesture + chevrons instead — works identically on
    /// touch (swipe) and trackpad/mouse (chevron tap) across both app targets.
    /// Only the top 3 are ever browsable, per docs/ARCHITECTURE.md §6.
    private var top3: [RankedCandidate] { Array(ranked.prefix(3)) }

    var body: some View {
        VStack(spacing: 12) {
            if top3.isEmpty {
                loadingCard
            } else {
                let clampedSelection = min(selection, top3.count - 1)
                card(for: top3[clampedSelection], rank: clampedSelection + 1)
                    .gesture(
                        DragGesture(minimumDistance: 24)
                            .onEnded { value in
                                if value.translation.width < 0 {
                                    selection = min(top3.count - 1, clampedSelection + 1)
                                } else if value.translation.width > 0 {
                                    selection = max(0, clampedSelection - 1)
                                }
                            }
                    )

                if top3.count > 1 {
                    pageControls(current: clampedSelection, count: top3.count)
                }

                controls(for: top3[clampedSelection])
            }
        }
        .onChange(of: ranked.map(\.id)) { _, _ in selection = 0 }
    }

    private func pageControls(current: Int, count: Int) -> some View {
        HStack(spacing: 14) {
            Button { selection = max(0, current - 1) } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(current == 0)

            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == current ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }

            Button { selection = min(count - 1, current + 1) } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(current == count - 1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private var loadingCard: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("finding a line that fits…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 200)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func card(for ranked: RankedCandidate, rank: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                providerBadge(for: ranked.candidate)
                Spacer()
                Text("rank \(rank)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(ranked.candidate.text)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            stressUnderline(for: ranked.candidate)

            syllableChips
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func providerBadge(for candidate: LyricCandidate) -> some View {
        HStack(spacing: 6) {
            if candidate.provider == .offline {
                Label("OFFLINE DRAFT", systemImage: "bolt.slash.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            } else {
                Label("CLAUDE", systemImage: "sparkles")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }
            if candidate.repaired {
                Text("repaired")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func stressUnderline(for candidate: LyricCandidate) -> some View {
        let groups = Self.wordStressGroups(for: candidate)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    VStack(spacing: 4) {
                        Text(group.display)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 3) {
                            ForEach(Array(group.stresses.enumerated()), id: \.offset) { _, stress in
                                Capsule()
                                    .fill(stress == .strong ? Color.accentColor : Color.secondary.opacity(0.4))
                                    .frame(width: stress == .strong ? 14 : 8, height: 4)
                            }
                        }
                    }
                }
            }
        }
    }

    private var syllableChips: some View {
        HStack(spacing: 8) {
            Button("−1 syllable") { onAdjustSyllables(-1) }
            Button("+1 syllable") { onAdjustSyllables(1) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.caption)
    }

    private func controls(for ranked: RankedCandidate) -> some View {
        HStack(spacing: 10) {
            Button("Use") { onUse(ranked) }
                .buttonStyle(.borderedProminent)

            Button("More Like This") { onMoreLikeThis(ranked) }
                .buttonStyle(.bordered)

            Button("Regenerate") { onRegenerate() }
                .buttonStyle(.bordered)

            Menu("Different Emotion") {
                ForEach(Emotion.allCases, id: \.self) { emotion in
                    Button(emotion.rawValue.capitalized) { onDifferentEmotion(emotion) }
                }
            }
            .buttonStyle(.bordered)
        }
        .font(.callout)
    }

    /// Word-level stress breakdown for the underline: `SyllableCounter` is the same
    /// on-device authority the ranker uses, so this always matches `stressAlignment`.
    private static func wordStressGroups(for candidate: LyricCandidate) -> [(display: String, stresses: [Stress])] {
        let displayWords = candidate.text.split(separator: " ").map(String.init)
        let cleanWords = SyllableCounter.words(in: candidate.text)
        guard displayWords.count == cleanWords.count, !displayWords.isEmpty else {
            return [(candidate.text, candidate.stressAlignment)]
        }
        return zip(displayWords, cleanWords).map { display, clean in
            (display, SyllableCounter.stressPattern(of: clean))
        }
    }
}

#Preview {
    SuggestionCardView(
        ranked: [
            RankedCandidate(
                candidate: LyricCandidate(
                    phraseID: UUID(), text: "all the miles between us",
                    syllableCount: 7, stressAlignment: [.weak, .strong, .weak, .strong, .weak, .strong, .weak],
                    provider: .offline
                ),
                score: LyricScore(syllableFit: 1, stressFit: 0.9, singability: 0.8, emotionalFit: 0.7, continuity: 0.6, memorability: 0.5)
            )
        ],
        onUse: { _ in }, onMoreLikeThis: { _ in }, onRegenerate: {}, onDifferentEmotion: { _ in }, onAdjustSyllables: { _ in }
    )
    .padding()
}
