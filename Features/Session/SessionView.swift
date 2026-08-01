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

    /// Chords carry no melody line to count syllables from, so the singer picks how
    /// many syllables per strum they intend to sing. Only shown when it can matter.
    private var showsDensityPicker: Bool {
        viewModel.inputMode == .rhythmic || viewModel.currentPhrase?.isRhythmOnly == true
    }

    /// True on the offline tier, whenever there is actually raw material to lead with.
    private var leadsWithSparks: Bool {
        viewModel.lastProviderKind == .offline && !(viewModel.currentSparks?.isEmpty ?? true)
    }

    private var suggestionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if leadsWithSparks {
                Text("OR START FROM A DRAFT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            SuggestionCardView(
                ranked: viewModel.rankedCandidates,
                onUse: { viewModel.use($0) },
                onMoreLikeThis: { viewModel.moreLikeThis($0) },
                onRegenerate: { viewModel.regenerate() },
                onDifferentEmotion: { viewModel.differentEmotion($0) },
                onAdjustSyllables: { viewModel.adjustSyllableTarget(by: $0) }
            )
        }
    }

    @ViewBuilder
    private var sparksSection: some View {
        if let sparks = viewModel.currentSparks, !sparks.isEmpty {
            SparksView(sparks: sparks)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
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
                    if viewModel.inputMode == .rhythmic {
                        RhythmBadge()
                    }
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

                FlowModeRow(
                    isOn: $viewModel.isFlowMode,
                    canUndo: !viewModel.sessionMemory.acceptedLines.isEmpty,
                    onUndo: { viewModel.undoLastAccepted() }
                )

                if viewModel.didHitFreeLimit, let proStore, !proStore.isPro {
                    freeLimitBanner
                }

                if showsDensityPicker {
                    DensityPicker(density: viewModel.density, onChange: { viewModel.setDensity($0) })
                }

                // Above the suggestion, not below it: the song being written is the
                // subject of this screen, and the suggestion is what's being offered
                // for the next line of it.
                if !viewModel.sessionMemory.acceptedLines.isEmpty {
                    SongSheetView(lines: viewModel.sessionMemory.acceptedLines)
                }

                if showsFinalStressPattern {
                    // Which half of the screen leads depends on which engine wrote the
                    // line. The offline assembler fits meter but has no model of meaning
                    // — it produces "warm in a doom" — so presenting its output as the
                    // answer misrepresents what it is. The words are meaningful by
                    // construction, so on that tier they lead and the draft sits under
                    // them as a starting point. On the AI tier the line is genuinely the
                    // answer and leads, as before.
                    // The card carries its own loading state, so it is shown while a
                    // request is genuinely in flight — but not once one has finished
                    // empty-handed, where it would spin with nothing coming.
                    let showsCard = viewModel.isGenerating || !viewModel.rankedCandidates.isEmpty
                    if leadsWithSparks {
                        sparksSection
                        if showsCard { suggestionCard }
                    } else {
                        if showsCard { suggestionCard }
                        sparksSection
                    }
                }

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
        // Follow the song down as it grows. Hands are on the instrument, so if the
        // writer had to scroll to see what was just kept, the sheet would be no more
        // use than the strip it replaced.
        .onChange(of: viewModel.sessionMemory.acceptedLines.count) { _, _ in
            guard let newest = viewModel.sessionMemory.acceptedLines.last else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(newest.id, anchor: .center)
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

/// Flow mode's control strip. The toggle is the only new decision the writer makes, and
/// they make it once — everything after that is hands-free: keep by playing on, undo by
/// tapping a pedal. The undo button carries a keyboard shortcut so it is reachable from a
/// pedal even though it is visually secondary.
private struct FlowModeRow: View {
    @Binding var isOn: Bool
    let canUndo: Bool
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $isOn) {
                HStack(spacing: 6) {
                    Image(systemName: isOn ? "figure.walk.motion" : "hand.tap")
                    Text("Flow mode")
                        .font(.footnote.weight(.medium))
                }
            }
            .toggleStyle(.switch)
            .fixedSize()
            .accessibilityHint("When on, every suggested line is written onto your song sheet as it arrives, so you never stop playing to accept one")

            Spacer()

            Button {
                onUndo()
            } label: {
                Label("Undo keep", systemImage: "arrow.uturn.backward")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canUndo)
            .keyboardShortcut("u", modifiers: [])
            .accessibilityHint("Removes the most recently kept line. Shortcut: U")
        }
        .padding(.horizontal, 2)
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
/// The song as it is being written: every kept line, in order, growing downward.
///
/// This replaces a three-line footnote strip that sat below the suggestion and the word
/// sparks. It was the only record that anything had been kept, it was truncated, and it
/// was far enough down the screen to be invisible in practice — so a session felt like a
/// sequence of disposable cards rather than a song accumulating. The sheet is the point
/// of the app; it reads like a lyric page, and the newest line is emphasised because
/// that is the one the writer just sang.
private struct SongSheetView: View {
    let lines: [LyricLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("YOUR SONG SO FAR")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(lines.count) \(lines.count == 1 ? "line" : "lines")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityHidden(true)

            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                let isNewest = index == lines.count - 1
                Text(line.text)
                    .font(.system(isNewest ? .title3 : .body, design: .rounded,
                                  weight: isNewest ? .semibold : .regular))
                    .foregroundStyle(isNewest ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(line.id)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your song so far, \(lines.count) lines")
        .accessibilityValue(lines.map(\.text).joined(separator: ". "))
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
