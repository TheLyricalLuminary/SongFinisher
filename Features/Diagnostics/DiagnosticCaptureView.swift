import SwiftUI
import Domain

/// Brutalist, monospace live DSP telemetry — Task 4's real-hardware validation tool.
/// No lyric generation; this view exists to make onset/pitch/segmentation quality on
/// real input (breath noise, mic proximity, natural dynamics) visually verifiable.
struct DiagnosticCaptureView: View {
    @State private var viewModel: DiagnosticCaptureViewModel
    @Environment(\.scenePhase) private var scenePhase

    init(services: AppServices) {
        _viewModel = State(initialValue: DiagnosticCaptureViewModel(services: services))
    }

    private static let bg = Color.black
    private static let fg = Color(white: 0.85)
    private static let dim = Color(white: 0.45)
    private static let accent = Color(red: 0.85, green: 0.85, blue: 0.1)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Self.dim)
            telemetryGrid
            Divider().background(Self.dim)
            controls
            Divider().background(Self.dim)
            log
        }
        .monospaced()
        .foregroundStyle(Self.fg)
        .background(Self.bg.ignoresSafeArea())
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { viewModel.stop() }
        }
        .onChange(of: viewModel.onsetTick) { _, _ in
            onsetFlash = true
            Task {
                try? await Task.sleep(for: .milliseconds(120))
                onsetFlash = false
            }
        }
    }

    private var header: some View {
        HStack {
            Text("SONGFINISHER // DSP DIAGNOSTIC")
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Text(stateLabel)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(stateColor)
        }
        .padding(12)
    }

    private var stateLabel: String {
        switch viewModel.state {
        case .idle: "IDLE"
        case .requestingPermission: "REQUESTING MIC…"
        case .permissionDenied: "MIC DENIED"
        case .listening: "LISTENING"
        case .failed: "FAILED"
        }
    }

    private var stateColor: Color {
        switch viewModel.state {
        case .listening: Self.accent
        case .failed, .permissionDenied: .red
        default: Self.dim
        }
    }

    private var telemetryGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow {
                metric("PITCH", pitchText)
                metric("NOTE", noteNameText)
                metric("CONF", String(format: "%.2f", viewModel.currentConfidence))
            }
            GridRow {
                metric("VOICED", viewModel.isVoiced ? "●" : "○")
                metric("TEMPO", tempoText)
                metric("PHRASES", "\(viewModel.completedPhraseCount)")
            }
            GridRow {
                metric("CHORD", chordText)
                metric("CH.CONF", String(format: "%.2f", viewModel.chord?.confidence ?? 0))
                Text("")
            }
            GridRow {
                Text("AMPLITUDE").font(.caption2).foregroundStyle(Self.dim)
                amplitudeBar
                    .gridCellColumns(2)
            }
            GridRow {
                Text("NOTES IN PHRASE").font(.caption2).foregroundStyle(Self.dim)
                Text("\(viewModel.liveNoteCountInPhrase)")
                    .font(.system(.body, design: .monospaced, weight: .bold))
                    .foregroundStyle(onsetFlash ? Self.accent : Self.fg)
                    .gridCellColumns(2)
            }
        }
        .padding(12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pitch \(pitchText), note \(noteNameText), amplitude \(String(format: "%.2f", viewModel.currentAmplitude)), \(viewModel.isVoiced ? "voiced" : "unvoiced")")
    }

    @State private var onsetFlash = false

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Self.dim)
            Text(value).font(.system(.body, design: .monospaced, weight: .semibold))
        }
    }

    private var amplitudeBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(white: 0.15))
                Rectangle()
                    .fill(viewModel.isVoiced ? Self.accent : Self.dim)
                    .frame(width: geo.size.width * CGFloat(min(1, viewModel.currentAmplitude * 6)))
            }
        }
        .frame(height: 14)
        .overlay(Rectangle().stroke(Self.dim, lineWidth: 1))
    }

    private var pitchText: String {
        guard let hz = viewModel.currentPitchHz else { return "—" }
        return String(format: "%.1f Hz", hz)
    }

    private var noteNameText: String {
        guard let midi = viewModel.currentMidiNote else { return "—" }
        return DiagnosticFormatting.noteName(midi: midi)
    }

    private var tempoText: String {
        guard let bpm = viewModel.tempoBPM, viewModel.tempoConfidence > 0.35 else { return "—" }
        return String(format: "%.0f BPM", bpm)
    }

    private var chordText: String {
        guard let chord = viewModel.chord, chord.isReliable else { return "—" }
        return chord.displayName
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                if viewModel.state == .listening || viewModel.state == .requestingPermission {
                    viewModel.stop()
                } else {
                    viewModel.start()
                }
            } label: {
                Text(viewModel.state == .listening ? "[ STOP ]" : "[ START ]")
                    .font(.system(.body, design: .monospaced, weight: .bold))
                    .foregroundStyle(Self.bg)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(viewModel.state == .listening ? Color.red : Self.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.state == .listening ? "Stop listening" : "Start listening")

            if viewModel.state == .permissionDenied {
                Button {
                    #if os(iOS)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    #endif
                } label: {
                    Text("[ OPEN SETTINGS ]")
                        .font(.system(.body, design: .monospaced, weight: .bold))
                        .foregroundStyle(Self.fg)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .overlay(Rectangle().stroke(Self.fg, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if case .failed(let message) = viewModel.state {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(12)
    }

    private var log: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(viewModel.noteLog.reversed()) { entry in
                    logRow(entry)
                }
                if viewModel.noteLog.isEmpty {
                    Text("// no completed phrases yet")
                        .font(.caption2)
                        .foregroundStyle(Self.dim)
                        .padding(.top, 8)
                }
            }
            .padding(12)
        }
        .accessibilityLabel("Note event log, \(viewModel.noteLog.count) entries")
    }

    private func logRow(_ entry: DiagnosticCaptureViewModel.NoteLogEntry) -> some View {
        let phrase = String(format: "p%02d", entry.phraseIndex)
        let onset = String(format: "onset=%6.2fs", entry.onset)
        let duration = String(format: "dur=%4dms", Int(entry.duration * 1000))
        let note = DiagnosticFormatting.noteName(midi: entry.midiNote).padding(toLength: 6, withPad: " ", startingAt: 0)
        let melisma = entry.isMelisma ? "MEL" : ""
        return Text("\(phrase)  \(onset)  \(duration)  \(note) \(melisma)")
            .font(.caption2)
            .foregroundStyle(entry.isMelisma ? Self.accent : Self.fg)
    }
}

enum DiagnosticFormatting {
    private static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    static func noteName(midi: Double) -> String {
        let rounded = Int(midi.rounded())
        let octave = rounded / 12 - 1
        let name = names[((rounded % 12) + 12) % 12]
        let cents = Int(((midi - Double(rounded)) * 100).rounded())
        let centsStr = cents == 0 ? "" : (cents > 0 ? "+\(cents)c" : "\(cents)c")
        return "\(name)\(octave)\(centsStr)"
    }
}

#Preview {
    DiagnosticCaptureView(services: .fakes())
}
