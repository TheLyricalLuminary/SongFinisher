import Foundation
import Domain

/// Task 4's live mic test (per the Phase 4 real-voice validation spec): taps the real
/// `AudioCapturing` → `MelodyAnalyzing` pipeline and surfaces raw DSP telemetry with
/// no lyric generation in the loop, so pitch/onset/segmentation quality on real
/// hardware (breath noise, mic proximity, natural performance dynamics) can be judged
/// by eye before LyricEngine is wired in.
@MainActor
@Observable
final class DiagnosticCaptureViewModel {
    enum CaptureState: Equatable {
        case idle
        case requestingPermission
        case permissionDenied
        case listening
        case failed(String)
    }

    struct NoteLogEntry: Identifiable, Equatable {
        let id = UUID()
        let phraseIndex: Int
        let onset: TimeInterval
        let duration: TimeInterval
        let midiNote: Double
        let isMelisma: Bool
        /// From a rhythm-only phrase: `midiNote` is a placeholder, render as a strum.
        var isRhythm = false
    }

    private(set) var state: CaptureState = .idle
    private(set) var currentPitchHz: Double?
    private(set) var currentMidiNote: Double?
    private(set) var currentAmplitude: Float = 0
    private(set) var currentConfidence: Float = 0
    private(set) var isVoiced = false
    private(set) var tempoBPM: Double?
    private(set) var tempoConfidence: Float = 0
    private(set) var liveNoteCountInPhrase = 0
    private(set) var completedPhraseCount = 0
    private(set) var noteLog: [NoteLogEntry] = []
    private(set) var inputMode: InputMode = .melodic

    /// Ticks up on every closed note — the view flashes on change as a visual "onset fired" cue.
    private(set) var onsetTick = 0

    static let maxLogEntries = 200
    /// Pitch frames arrive at 100 Hz; UI updates are throttled to ~30 fps
    /// (docs/ARCHITECTURE.md §5 UI guidance) using the frame's own analysis-clock time.
    static let uiUpdateInterval: TimeInterval = 1.0 / 30.0

    private let services: AppServices
    private var pipelineTask: Task<Void, Never>?
    private var lastPitchUIUpdate: TimeInterval = -1

    init(services: AppServices) {
        self.services = services
    }

    func start() {
        guard pipelineTask == nil else { return }
        resetTelemetry()
        pipelineTask = Task { [weak self] in await self?.run() }
    }

    func stop() {
        pipelineTask?.cancel()
        pipelineTask = nil
        let capture = services.capture
        Task { await capture.stop() }
        state = .idle
    }

    /// Clears prior-session data so a restart never shows ghost telemetry from the
    /// previous take, and rewinds the throttle clock so it doesn't compare the new
    /// session's near-zero `frame.time` against the old session's high-water mark
    /// (each `analyze()` call runs a fresh `AnalysisChain`, so its clock restarts too).
    private func resetTelemetry() {
        lastPitchUIUpdate = -1
        currentPitchHz = nil
        currentMidiNote = nil
        currentAmplitude = 0
        currentConfidence = 0
        isVoiced = false
        tempoBPM = nil
        tempoConfidence = 0
        liveNoteCountInPhrase = 0
        completedPhraseCount = 0
        onsetTick = 0
        inputMode = .melodic
        noteLog.removeAll(keepingCapacity: true)
    }

    private func run() async {
        // A start() immediately followed by stop() cancels this task before it ever
        // runs; without this guard the state write below would clobber stop()'s
        // synchronous `.idle` the moment the scheduler gets to it.
        guard !Task.isCancelled else { return }

        state = .requestingPermission
        let current = await services.permissions.currentMicPermission()
        let granted: Bool
        switch current {
        case .granted: granted = true
        case .denied: granted = false
        case .undetermined: granted = await services.permissions.requestMicPermission() == .granted
        }
        guard granted else {
            if !Task.isCancelled { state = .permissionDenied; pipelineTask = nil }
            return
        }
        guard !Task.isCancelled else { return }

        do throws(CaptureError) {
            let chunks = try await services.capture.start()
            guard !Task.isCancelled else { return }
            state = .listening
            for await event in services.analyzer.analyze(chunks) {
                if Task.isCancelled { break }
                handle(event)
            }
            // The stream can end on its own (not just via stop()'s cancellation) —
            // e.g. a fake/test double that finishes immediately. Without resetting
            // pipelineTask here, the next start() call is silently blocked by the
            // `guard pipelineTask == nil` check. Skipped when cancelled: stop()
            // already performed this cleanup synchronously.
            if !Task.isCancelled {
                state = .idle
                pipelineTask = nil
            }
        } catch {
            if !Task.isCancelled {
                state = .failed("\(error)")
                pipelineTask = nil
            }
        }
    }

    private func handle(_ event: AnalysisEvent) {
        switch event {
        case .pitch(let frame):
            guard frame.time - lastPitchUIUpdate >= Self.uiUpdateInterval else { return }
            lastPitchUIUpdate = frame.time
            currentPitchHz = frame.frequencyHz
            currentMidiNote = frame.midiNote
            currentAmplitude = frame.rmsEnergy
            currentConfidence = frame.confidence
            isVoiced = frame.isVoiced

        case .tempoUpdated(let tempo):
            tempoBPM = tempo.bpm
            tempoConfidence = tempo.confidence

        case .phraseInProgress(_, let provisionalNotes):
            if provisionalNotes > liveNoteCountInPhrase { onsetTick += 1 }
            liveNoteCountInPhrase = provisionalNotes

        case .phraseCompleted(let phrase):
            completedPhraseCount += 1
            liveNoteCountInPhrase = 0
            for note in phrase.notes {
                noteLog.append(NoteLogEntry(
                    phraseIndex: phrase.index, onset: note.onset, duration: note.duration,
                    midiNote: note.midiNote, isMelisma: note.isMelisma,
                    isRhythm: phrase.isRhythmOnly
                ))
            }
            if noteLog.count > Self.maxLogEntries {
                noteLog.removeFirst(noteLog.count - Self.maxLogEntries)
            }

        case .inputModeChanged(let mode):
            inputMode = mode
        }
    }
}
