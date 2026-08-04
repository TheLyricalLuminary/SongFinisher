import SwiftUI
import Domain

/// The top-ranked candidate, swipeable to rank 2–3, with the per-syllable stress
/// underline, provider badge, and the four intent controls from docs/ARCHITECTURE.md §9.
struct SuggestionCardView: View {
    let ranked: [RankedCandidate]
    /// The stress pattern the *melody* produced, so the card can show the fit against it
    /// rather than only showing the line's own stress and leaving the comparison to the
    /// reader. Empty when no phrase has been analysed yet.
    let melodyPattern: [Stress]
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
            .keyboardShortcut(.leftArrow, modifiers: [])
            .accessibilityLabel("Previous suggestion")

            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == current ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
            .accessibilityHidden(true)

            Button { selection = min(count - 1, current + 1) } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(current == count - 1)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .accessibilityLabel("Next suggestion")
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Finding a line that fits")
    }

    private func card(for ranked: RankedCandidate, rank: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // The line itself plus its metadata read as one VoiceOver element; the stress
            // underline is a visual duplicate of the syllable info and stays hidden.
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
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Suggestion \(rank): \(ranked.candidate.text)")
            .accessibilityValue("\(ranked.candidate.syllableCount) syllables, \(providerSpokenName(for: ranked.candidate))")

            // Outside the merged element above so VoiceOver reaches the fit as its own
            // item — it answers a different question from "what does the line say".
            MelodyFitView(candidate: ranked.candidate, melodyPattern: melodyPattern)

            syllableChips
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    /// Honest provenance (App Store fairness as much as UX): the on-device AI tier and the
    /// deterministic offline assembler are clearly distinguished so a user on
    /// non-Apple-Intelligence hardware is never told a template line was "AI".
    private func providerBadge(for candidate: LyricCandidate) -> some View {
        HStack(spacing: 6) {
            switch candidate.provider {
            case .offline:
                Label("OFFLINE DRAFT", systemImage: "bolt.slash.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            case .appleIntelligence:
                Label("ON-DEVICE AI", systemImage: "sparkles")
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

    private func providerSpokenName(for candidate: LyricCandidate) -> String {
        switch candidate.provider {
        case .appleIntelligence: "written by on-device AI"
        case .offline: "offline draft"
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
                .accessibilityLabel("One fewer syllable")
                .accessibilityHint("Requests new lines one syllable shorter")
            Button("+1 syllable") { onAdjustSyllables(1) }
                .accessibilityLabel("One more syllable")
                .accessibilityHint("Requests new lines one syllable longer")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.caption)
    }

    private func controls(for ranked: RankedCandidate) -> some View {
        HStack(spacing: 10) {
            // Keyboard shortcuts exist so hands never leave the instrument: Bluetooth
            // page-turner pedals (AirTurn, PageFlip — hardware guitarists already own)
            // present as HID keyboards sending exactly these keys, so binding them here
            // makes the whole card foot-operable for free, with no pairing code of ours.
            Button("Use") { onUse(ranked) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityHint("Adds this line to your song and returns to listening. Shortcut: space")

            Button("More Like This") { onMoreLikeThis(ranked) }
                .buttonStyle(.bordered)
                .keyboardShortcut("m", modifiers: [])
                .accessibilityHint("Requests new lines close to this one's imagery. Shortcut: M")

            Button("Regenerate") { onRegenerate() }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: [])
                .accessibilityHint("Replaces these suggestions with fresh ones. Shortcut: R")

            Menu("Different Emotion") {
                ForEach(Emotion.allCases, id: \.self) { emotion in
                    Button(emotion.rawValue.capitalized) { onDifferentEmotion(emotion) }
                }
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Requests new lines in a mood you choose")
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

/// Shows the melody's stress pattern and the line's stress pattern on one axis, syllable
/// by syllable, so the fit between them is *visible*.
///
/// Both halves were already on screen — the melody's pattern under SYLLABLES, the line's
/// under the words — but in separate places, which asked the songwriter to hold two
/// patterns in their head and compare. Nobody does that, so the most distinctive thing
/// the app does read as though it might be guessing. This is the answer to "how do I know
/// it's calculating to my melody?", on the card, in the moment.
private struct MelodyFitView: View {
    let candidate: LyricCandidate
    let melodyPattern: [Stress]

    /// One syllable's worth of comparison.
    private struct Slot {
        let melody: Stress
        let line: Stress
        var matches: Bool { melody == line }
    }

    private var slots: [Slot] {
        // A repaired line can come back a syllable off the target, so compare only as far
        // as both patterns reach and let the caption carry the length difference.
        zip(melodyPattern, candidate.stressAlignment).map { pair in
            Slot(melody: pair.0, line: pair.1)
        }
    }

    private var matchCount: Int { slots.filter(\.matches).count }

    var body: some View {
        if !slots.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                        column(for: slot)
                    }
                }
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(matchCount == slots.count ? Color.accentColor : .secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Fit to your melody")
            .accessibilityValue(caption)
        }
    }

    /// Melody on top, line beneath: a matched pair reads as one solid column, a mismatch
    /// visibly breaks. Width encodes stress so the shape of the melody is legible on its
    /// own row rather than only through colour — which also keeps it readable for anyone
    /// who can't distinguish the two tints.
    private func column(for slot: Slot) -> some View {
        VStack(spacing: 3) {
            mark(slot.melody, tint: .secondary.opacity(0.55))
            mark(slot.line, tint: slot.matches ? Color.accentColor : .orange)
        }
    }

    private func mark(_ stress: Stress, tint: Color) -> some View {
        Capsule()
            .fill(tint)
            .frame(width: stress == .strong ? 14 : 7, height: 4)
    }

    private var caption: String {
        let lineCount = candidate.stressAlignment.count
        let melodyCount = melodyPattern.count
        let lengthNote = lineCount == melodyCount
            ? ""
            : " · \(lineCount) syllables against \(melodyCount) played"
        if matchCount == slots.count {
            return "every syllable lands on your melody's beats\(lengthNote)"
        }
        return "\(matchCount) of \(slots.count) land on your melody's beats\(lengthNote)"
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
        melodyPattern: [.weak, .strong, .weak, .strong, .weak, .strong, .weak],
        onUse: { _ in }, onMoreLikeThis: { _ in }, onRegenerate: {}, onDifferentEmotion: { _ in }, onAdjustSyllables: { _ in }
    )
    .padding()
}
