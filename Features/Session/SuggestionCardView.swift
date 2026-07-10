import SwiftUI
import Domain

/// The top-ranked candidate for the current phrase, plus up to two alternates and the
/// full action set from docs/ARCHITECTURE.md §6: Use / More Like This / Regenerate /
/// Different Emotion, and the ±1-syllable escape hatch for budget mismatches.
struct SuggestionCardView: View {
    let ranked: RankedCandidate
    let alternates: [RankedCandidate]
    let spec: PhraseSpec?
    let onUse: (LyricCandidate) -> Void
    let onMoreLikeThis: (LyricCandidate) -> Void
    let onRegenerate: () -> Void
    let onDifferentEmotion: (Emotion) -> Void
    let onAdjustSyllables: (Int) -> Void
    let onDismiss: (LyricCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(ranked.candidate.text)
                .font(.title3.weight(.semibold))
            stressUnderline
            if !withinBudget {
                syllableEscapeHatch
            }
            actions
            if !alternates.isEmpty {
                alternatesRow
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var header: some View {
        HStack {
            Text(ranked.candidate.provider == .offline ? "OFFLINE DRAFT" : "CLAUDE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(ranked.candidate.syllableCount) syl")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// A dot per syllable, filled for the stresses the target stress map marks Strong,
    /// so a misstressed candidate ("toDAY i FOUND" against a "SwS" target) reads as
    /// visually wrong at a glance.
    private var stressUnderline: some View {
        HStack(spacing: 4) {
            ForEach(Array(ranked.candidate.stressAlignment.enumerated()), id: \.offset) { _, stress in
                Circle()
                    .fill(stress == .strong ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var withinBudget: Bool {
        guard let budget = spec?.budget else { return true }
        return budget.contains(ranked.candidate.syllableCount)
    }

    private var syllableEscapeHatch: some View {
        HStack(spacing: 8) {
            Text("Off by \(abs(ranked.candidate.syllableCount - (spec?.budget.target ?? ranked.candidate.syllableCount)))")
                .font(.caption)
                .foregroundStyle(.orange)
            Button("−1 syllable") { onAdjustSyllables(-1) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("+1 syllable") { onAdjustSyllables(1) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Use") { onUse(ranked.candidate) }
                .buttonStyle(.borderedProminent)
            Button("More Like This") { onMoreLikeThis(ranked.candidate) }
                .buttonStyle(.bordered)
            Button("Regenerate") { onRegenerate() }
                .buttonStyle(.bordered)
            Menu("Different Emotion") {
                ForEach(Emotion.allCases, id: \.self) { emotion in
                    Button(emotion.rawValue.capitalized) { onDifferentEmotion(emotion) }
                }
            }
            Spacer()
            Button {
                onDismiss(ranked.candidate)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss suggestion")
        }
        .font(.footnote)
    }

    private var alternatesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(alternates) { alt in
                Button {
                    onUse(alt.candidate)
                } label: {
                    Text(alt.candidate.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }
}
