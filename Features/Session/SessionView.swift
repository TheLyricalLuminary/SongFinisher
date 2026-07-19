import SwiftUI
import Domain

/// The main "Listening…" screen (docs/ARCHITECTURE.md §6). Works the same whether the
/// melody came from a voice or an instrument plugged into the input device — everything
/// downstream only ever sees pitch/onset/amplitude.
struct SessionView: View {
    @State private var viewModel: SessionViewModel
    @Environment(\.scenePhase) private var scenePhase

    init(services: AppServices) {
        _viewModel = State(initialValue: SessionViewModel(services: services))
    }

    private var showsFinalStressPattern: Bool {
        viewModel.state == .analyzingPhrase || viewModel.state == .suggesting
    }

    /// Chords carry no melody line to count syllables from, so the singer picks how
    /// many syllables per strum they intend to sing. Only shown when it can matter.
    private var showsDensityPicker: Bool {
        viewModel.inputMode == .rhythmic || viewModel.currentPhrase?.isRhythmOnly == true
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
                    ConfidenceDot(confidence: viewModel.currentConfidence)
                    Spacer()
                    if viewModel.inputMode == .rhythmic {
                        RhythmBadge()
                    }
                }

                WaveformView(energyHistory: viewModel.energyHistory, isVoiced: viewModel.isVoiced)

                VStack(alignment: .leading, spacing: 8) {
                    Text("SYLLABLES")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                    SyllableMeterView(
                        finalPattern: showsFinalStressPattern ? viewModel.currentSpec?.budget.stressMap.pattern : nil,
                        liveCount: viewModel.liveNoteCountInPhrase
                    )
                }

                if showsDensityPicker {
                    DensityPicker(density: viewModel.density, onChange: { viewModel.setDensity($0) })
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

                    if let sparks = viewModel.currentSparks, !sparks.isEmpty {
                        SparksView(sparks: sparks)
                    }
                }

                AcceptedLinesStrip(lines: viewModel.sessionMemory.acceptedLines)
            }
            .padding(20)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { viewModel.stop() }
        }
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
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 80, height: 80)
                    .background(buttonColor, in: Circle())
                    .scaleEffect(pulse ? 1.08 : 1.0)
            }
            .buttonStyle(.plain)
            .animation(pulse ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
            .frame(maxWidth: .infinity)
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
    /// Hardcoded rather than `.accentColor` — the system accent can itself be red, which
    /// would erase the idle/listening contrast this button exists to convey.
    private var buttonColor: Color { isActive ? .red : Color(red: 0.35, green: 0.4, blue: 0.55) }

    private var statusPill: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
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
    }
}

private struct TempoBadge: View {
    let tempo: TempoEstimate?

    var body: some View {
        Label(label, systemImage: "metronome.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private var label: String {
        guard let tempo, tempo.isReliable else { return "~" }
        return "\(Int(tempo.bpm.rounded())) BPM"
    }
}

private struct ConfidenceDot: View {
    let confidence: Float

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
    }

    private var color: Color {
        if confidence >= 0.7 { return .green }
        if confidence >= 0.4 { return .yellow }
        return .red
    }
}

/// Shown when the DSP chain has classified the input as strummed chords rather than
/// a single melodic line — YIN pitch tracking is meaningless there, so the syllable
/// budget comes from the onset grid instead (see `DensityPicker` below).
private struct RhythmBadge: View {
    var body: some View {
        Label("Rhythm", systemImage: "waveform.path")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
            .accessibilityLabel("Rhythm mode: hearing strummed chords")
    }
}

/// Sparse/medium/dense selector for strummed input: chords carry no melody line to
/// count syllables from, so the singer states how many syllables per strum they
/// intend to sing, and the onset grid supplies the accents.
private struct DensityPicker: View {
    let density: SyllableDensity
    let onChange: (SyllableDensity) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SYLLABLES PER STRUM")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
            Picker("Syllables per strum", selection: Binding(get: { density }, set: onChange)) {
                ForEach(SyllableDensity.allCases, id: \.self) { option in
                    Text(option.rawValue.capitalized).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
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
        }
    }
}

/// The honest offline offering: not a finished line, but raw material. Strong words
/// that fit the phrase's feeling and beat, and rhymes for the last accepted line — the
/// songwriter writes the line. A word-level generator can't guarantee meaning, so this
/// gives real, usable vocabulary instead of a metrically-correct nonsense sentence.
private struct SparksView: View {
    let sparks: WordSparks

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !sparks.images.isEmpty {
                chipSection(title: "WORDS THAT FIT", words: sparks.images, tint: .accentColor)
            }
            if !sparks.rhymes.isEmpty {
                chipSection(title: "RHYMES WITH YOUR LAST LINE", words: sparks.rhymes, tint: .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipSection(title: String, words: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(words, id: \.self) { word in
                        Text(word)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(tint.opacity(0.12), in: Capsule())
                            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
                    }
                }
            }
        }
    }
}

#Preview {
    SessionView(services: .fakes())
}
