import SwiftUI
import Domain

/// The main "Listening…" screen (docs/ARCHITECTURE.md §6). Works the same whether the
/// melody came from a voice or an instrument plugged into the input device — everything
/// downstream only ever sees pitch/onset/amplitude.
///
/// Backgrounding does NOT stop an active session: the audio background mode keeps capture
/// alive and the Live Activity (lock screen / Dynamic Island) shows progress, so a writer
/// can lock the phone mid-hum without losing the take. Leaving the screen entirely
/// (`onDisappear`) still tears capture down — navigation away is an explicit exit.
struct SessionView: View {
    @State private var viewModel: SessionViewModel
    @State private var showsPaywall = false

    /// `nil` proStore = unmetered (previews, diagnostics, tests).
    private let proStore: ProStore?

    init(
        services: AppServices,
        songID: UUID? = nil,
        songTitle: String? = nil,
        initialMemory: SessionMemory = SessionMemory(),
        proStore: ProStore? = nil
    ) {
        self.proStore = proStore
        _viewModel = State(initialValue: SessionViewModel(
            services: services, songID: songID, songTitle: songTitle,
            initialMemory: initialMemory, gating: proStore
        ))
    }

    private var showsFinalStressPattern: Bool {
        viewModel.state == .analyzingPhrase || viewModel.state == .suggesting
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ListeningHeader(state: viewModel.state, onToggle: toggleCapture)

                if case .failed(let message) = viewModel.state {
                    banner(message, tint: .red)
                } else if viewModel.state == .permissionDenied {
                    permissionDeniedBanner
                } else if let error = viewModel.generationError {
                    banner(error, tint: .orange)
                }

                HStack(spacing: 16) {
                    MoodBadge(emotion: viewModel.currentSpec?.topEmotions.first?.emotion ?? viewModel.sessionMemory.dominantEmotion)
                    TempoBadge(tempo: viewModel.currentTempo)
                    ChordBadge(chord: viewModel.currentChord)
                    ConfidenceDot(confidence: viewModel.currentConfidence)
                    Spacer()
                }

                WaveformView(energyHistory: viewModel.energyHistory, isVoiced: viewModel.isVoiced)

                VStack(alignment: .leading, spacing: 8) {
                    Text("SYLLABLES")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    SyllableMeterView(
                        finalPattern: showsFinalStressPattern ? viewModel.currentSpec?.budget.stressMap.pattern : nil,
                        liveCount: viewModel.liveNoteCountInPhrase
                    )
                }

                if viewModel.didHitFreeLimit, let proStore, !proStore.isPro {
                    freeLimitBanner
                }

                if showsFinalStressPattern {
                    SuggestionCardView(
                        ranked: viewModel.rankedCandidates,
                        onUse: { viewModel.use($0) },
                        onMoreLikeThis: { viewModel.moreLikeThis($0) },
                        onRegenerate: { viewModel.regenerate() },
                        onDifferentEmotion: { viewModel.differentEmotion($0) },
                        onAdjustSyllables: { viewModel.adjustSyllableTarget(by: $0) }
                    )
                }

                AcceptedLinesStrip(lines: viewModel.sessionMemory.acceptedLines)
            }
            .padding(20)
        }
        .appBackground()
        // VoiceOver users can't watch the card fade in — announce arrivals explicitly.
        .onChange(of: viewModel.rankedCandidates.first?.id) { _, newValue in
            if newValue != nil {
                AccessibilityNotification.Announcement("New lyric lines ready").post()
            }
        }
        // Popping back to the library must release the mic/engine — a session screen is no
        // longer the permanent root, so leaving it has to tear capture down.
        .onDisappear { viewModel.stop() }
        .sheet(isPresented: $showsPaywall) {
            if let proStore {
                PaywallView(store: proStore)
            }
        }
    }

    private var freeLimitBanner: some View {
        Button {
            showsPaywall = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.brand)
                Text("Free AI lines used for today — drafts continue offline.")
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.leading)
                Spacer()
                Text("Go Pro")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.brand)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Free AI lines used for today. Drafts continue offline.")
        .accessibilityHint("Opens Song Finisher Pro upgrade options")
    }

    private func toggleCapture() {
        switch viewModel.state {
        case .listening, .analyzingPhrase, .suggesting, .requestingPermission:
            viewModel.stop()
        default:
            viewModel.start()
        }
    }

    private var permissionDeniedBanner: some View {
        HStack {
            banner("Microphone access is off.", tint: .red)
            #if os(iOS)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Opens the Settings app to enable microphone access")
            #endif
        }
    }

    private func banner(_ message: String, tint: Color) -> some View {
        Text(message)
            .font(.footnote.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ListeningHeader: View {
    let state: SessionViewModel.SessionState
    let onToggle: () -> Void

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var buttonDiameter: CGFloat = 80
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 30

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Song Finisher")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                Spacer()
                statusPill
            }

            Button(action: onToggle) {
                Image(systemName: iconName)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: buttonDiameter, height: buttonDiameter)
                    .background(buttonBackground, in: Circle())
                    .shadow(color: shadowColor, radius: 12, y: 4)
                    .scaleEffect(pulse && !reduceMotion ? 1.08 : 1.0)
            }
            .buttonStyle(.plain)
            .animation(
                pulse && !reduceMotion
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .frame(maxWidth: .infinity)
            .accessibilityLabel(isActive ? "Stop listening" : "Start listening")
            .accessibilityHint(isActive ? "Ends the session" : "Listens to your melody and suggests lyrics that fit it")
        }
        .onChange(of: state) { _, newValue in
            pulse = (newValue == .listening)
        }
    }

    private var isActive: Bool {
        switch state {
        case .listening, .analyzingPhrase, .suggesting, .requestingPermission: true
        default: false
        }
    }

    private var iconName: String { isActive ? "stop.fill" : "mic.fill" }

    /// Brand gradient rather than `.accentColor` — the accent asset is the same hue, but
    /// the idle/listening contrast this button conveys must never depend on a tint that
    /// could be re-themed toward red.
    private var buttonBackground: LinearGradient {
        isActive
            ? LinearGradient(
                colors: [Color(red: 0.92, green: 0.32, blue: 0.32), Color(red: 0.72, green: 0.18, blue: 0.22)],
                startPoint: .top, endPoint: .bottom
              )
            : LinearGradient(colors: [.brand, .brandDeep], startPoint: .top, endPoint: .bottom)
    }

    private var shadowColor: Color {
        (isActive ? Color.red : Color.brand).opacity(0.35)
    }

    private var statusPill: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("Session status: \(spokenLabel)")
    }

    private var label: String {
        switch state {
        case .idle: "IDLE"
        case .requestingPermission: "REQUESTING MIC…"
        case .permissionDenied: "MIC DENIED"
        case .listening: "LISTENING"
        case .analyzingPhrase: "ANALYZING"
        case .suggesting: "SUGGESTING"
        case .failed: "ERROR"
        }
    }

    private var spokenLabel: String {
        switch state {
        case .idle: "idle"
        case .requestingPermission: "requesting microphone access"
        case .permissionDenied: "microphone access denied"
        case .listening: "listening"
        case .analyzingPhrase: "analyzing phrase"
        case .suggesting: "suggesting lines"
        case .failed: "error"
        }
    }

    private var color: Color {
        switch state {
        case .listening: .green
        case .analyzingPhrase, .suggesting: .accentColor
        case .permissionDenied, .failed: .red
        default: .secondary
        }
    }
}

private struct MoodBadge: View {
    let emotion: Emotion?

    var body: some View {
        Label(emotion?.rawValue.capitalized ?? "—", systemImage: "theatermasks.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(emotion.map { "Mood: \($0.rawValue)" } ?? "Mood: not yet detected")
    }
}

private struct TempoBadge: View {
    let tempo: TempoEstimate?

    var body: some View {
        Label(label, systemImage: "metronome.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibleLabel)
    }

    private var label: String {
        guard let tempo, tempo.isReliable else { return "~" }
        return "\(Int(tempo.bpm.rounded())) BPM"
    }

    private var accessibleLabel: String {
        guard let tempo, tempo.isReliable else { return "Tempo: not yet detected" }
        return "Tempo: \(Int(tempo.bpm.rounded())) beats per minute"
    }
}

/// Live harmony read from `ChordDetector` — shown only once the match is confident
/// enough to trust (docs/ARCHITECTURE.md §8 companion); otherwise it's noise, not signal.
private struct ChordBadge: View {
    let chord: ChordEstimate?

    var body: some View {
        Label(label, systemImage: "pianokeys")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibleLabel)
    }

    private var label: String {
        guard let chord, chord.isReliable else { return "—" }
        return chord.displayName
    }

    private var accessibleLabel: String {
        // "Am" reads as the word "am" — VoiceOver gets the spelled-out chord name.
        guard let chord, chord.isReliable else { return "Chord: not yet detected" }
        return "Chord: \(chord.spokenName)"
    }
}

private struct ConfidenceDot: View {
    let confidence: Float

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pitch signal")
            .accessibilityValue(spokenLevel)
    }

    private var color: Color {
        if confidence >= 0.7 { return .green }
        if confidence >= 0.4 { return .yellow }
        return .red
    }

    private var spokenLevel: String {
        if confidence >= 0.7 { return "strong" }
        if confidence >= 0.4 { return "moderate" }
        return "weak"
    }
}

/// "●○●○○●○" per docs/ARCHITECTURE.md §6: while a phrase is being sung/played, dots grow
/// one at a time with no stress info yet (we don't know the final map until the phrase
/// ends); once it completes, the dots snap to the real S/w pattern for that phrase.
private struct SyllableMeterView: View {
    let finalPattern: [Stress]?
    let liveCount: Int

    var body: some View {
        HStack(spacing: 6) {
            if let pattern = finalPattern, !pattern.isEmpty {
                ForEach(Array(pattern.enumerated()), id: \.offset) { _, stress in
                    dot(stress: stress)
                }
            } else if liveCount > 0 {
                ForEach(0..<liveCount, id: \.self) { _ in
                    Circle().fill(Color.secondary.opacity(0.6)).frame(width: 8, height: 8)
                }
            } else {
                Text("waiting for a phrase…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Syllable pattern")
        .accessibilityValue(accessibleValue)
    }

    private var accessibleValue: String {
        if let pattern = finalPattern, !pattern.isEmpty {
            let stressedPositions = pattern.indices.filter { pattern[$0] == .strong }.map { "\($0 + 1)" }
            let stresses = stressedPositions.isEmpty
                ? "no stressed syllables"
                : "stressed on syllable \(stressedPositions.joined(separator: ", "))"
            return "\(pattern.count) syllables, \(stresses)"
        }
        if liveCount > 0 {
            return liveCount == 1 ? "1 note so far" : "\(liveCount) notes so far"
        }
        return "waiting for a phrase"
    }

    @ViewBuilder
    private func dot(stress: Stress) -> some View {
        if stress == .strong {
            Circle().fill(Color.accentColor).frame(width: 11, height: 11)
        } else {
            Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5).frame(width: 11, height: 11)
        }
    }
}

/// Last 3 accepted lines. Tapping through to the full song sheet is a later phase
/// (docs/ARCHITECTURE.md §15 build plan item 6) — this is a passive recap for now.
private struct AcceptedLinesStrip: View {
    let lines: [LyricLine]

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("ACCEPTED")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                ForEach(lines.suffix(3)) { line in
                    Text(line.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Accepted lines")
            .accessibilityValue(lines.suffix(3).map(\.text).joined(separator: ". "))
        }
    }
}

#Preview {
    SessionView(services: .fakes())
}
