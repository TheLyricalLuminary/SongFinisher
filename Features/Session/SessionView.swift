import SwiftUI
import Domain

/// The main "Listening…" screen (docs/ARCHITECTURE.md §6) — Phase 4's offline loop made
/// visible: capture → phrase segmentation → prosody → offline lyric candidates → ranking,
/// entirely on-device. `DiagnosticCaptureView` remains the raw-DSP validation tool this
/// was built alongside; this view is the actual product surface.
struct SessionView: View {
    @State private var viewModel: SessionViewModel
    @Environment(\.scenePhase) private var scenePhase

    init(services: AppServices) {
        _viewModel = State(initialValue: SessionViewModel(services: services))
    }

    var body: some View {
        VStack(spacing: 0) {
            listeningHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    syllableMeter
                    suggestionCard
                    if let error = viewModel.generationError {
                        errorBanner(error)
                    }
                }
                .padding()
            }
            Divider()
            acceptedLinesStrip
            controls
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { viewModel.stop() }
        }
    }

    // MARK: - Header

    private var listeningHeader: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(stateColor)
                .frame(width: 10, height: 10)
            Text(stateLabel)
                .font(.headline)
            Spacer()
            if let tempo = viewModel.tempo, tempo.isReliable {
                Label(String(format: "%.0f BPM", tempo.bpm), systemImage: "metronome")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let emotion = viewModel.currentSpec?.topEmotions.first?.emotion {
                Text(emotion.rawValue.capitalized)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
            }
        }
        .padding()
        .accessibilityElement(children: .combine)
    }

    private var stateLabel: String {
        switch viewModel.state {
        case .idle: "Idle"
        case .requestingPermission: "Requesting microphone…"
        case .permissionDenied: "Microphone access denied"
        case .listening: "Listening…"
        case .analyzingPhrase: "Analyzing phrase…"
        case .suggesting: "Finding lyrics…"
        case .failed: "Something went wrong"
        }
    }

    private var stateColor: Color {
        switch viewModel.state {
        case .listening: .green
        case .analyzingPhrase, .suggesting, .requestingPermission: .yellow
        case .failed, .permissionDenied: .red
        case .idle: .gray
        }
    }

    // MARK: - Syllable meter

    /// Fills LIVE while singing (provisional note count against no fixed target yet);
    /// once a phrase completes, shows the derived stress map's Strong/weak dots.
    private var syllableMeter: some View {
        HStack(spacing: 6) {
            if let pattern = viewModel.currentSpec?.budget.stressMap.pattern, !pattern.isEmpty {
                ForEach(Array(pattern.enumerated()), id: \.offset) { _, stress in
                    Circle()
                        .strokeBorder(.secondary, lineWidth: 1)
                        .background(Circle().fill(stress == .strong ? Color.accentColor : .clear))
                        .frame(width: stress == .strong ? 14 : 10, height: stress == .strong ? 14 : 10)
                }
            } else if viewModel.state == .listening {
                ForEach(0..<max(viewModel.liveSyllableCount, 1), id: \.self) { _ in
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                }
            }
        }
        .frame(minHeight: 16)
        .accessibilityLabel("Syllable meter")
        .accessibilityValue(viewModel.currentSpec.map { "\($0.budget.target) syllables" } ?? "\(viewModel.liveSyllableCount) notes so far")
    }

    // MARK: - Suggestion card

    @ViewBuilder
    private var suggestionCard: some View {
        if let top = viewModel.ranked.first {
            SuggestionCardView(
                ranked: top,
                alternates: Array(viewModel.ranked.dropFirst().prefix(2)),
                spec: viewModel.currentSpec,
                onUse: { viewModel.accept($0) },
                onMoreLikeThis: { viewModel.moreLikeThis($0) },
                onRegenerate: { viewModel.regenerate() },
                onDifferentEmotion: { viewModel.requestDifferentEmotion($0) },
                onAdjustSyllables: { viewModel.adjustSyllableTarget(by: $0) },
                onDismiss: { viewModel.dismiss($0) }
            )
        } else if viewModel.state == .analyzingPhrase || viewModel.state == .suggesting {
            HStack {
                ProgressView()
                Text(viewModel.state == .analyzingPhrase ? "Reading the phrase…" : "Writing suggestions…")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func errorBanner(_ error: LyricProviderError) -> some View {
        Label(message(for: error), systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func message(for error: LyricProviderError) -> String {
        switch error {
        case .network: "No connection — showing offline suggestions where possible."
        case .rateLimited: "Rate limited — try again shortly."
        case .invalidResponse: "Couldn't parse a suggestion for this phrase."
        case .unauthorized: "Add an API key in Settings to use Claude suggestions."
        case .cancelled: ""
        }
    }

    // MARK: - Accepted lines

    private var acceptedLinesStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(viewModel.acceptedLines.suffix(3)) { line in
                Text(line.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if viewModel.acceptedLines.isEmpty {
                Text("Accepted lines will appear here.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    // MARK: - Controls

    private var controls: some View {
        HStack {
            Button {
                if viewModel.state == .permissionDenied {
                    #if os(iOS)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    #endif
                } else if viewModel.state == .idle {
                    viewModel.start()
                } else {
                    viewModel.stop()
                }
            } label: {
                Label(controlLabel, systemImage: controlSymbol)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }

    private var controlLabel: String {
        switch viewModel.state {
        case .permissionDenied: "Open Settings"
        case .idle: "Start listening"
        default: "Stop"
        }
    }

    private var controlSymbol: String {
        switch viewModel.state {
        case .permissionDenied: "gear"
        case .idle: "mic"
        default: "stop.fill"
        }
    }
}

#Preview {
    SessionView(services: .fakes())
}
