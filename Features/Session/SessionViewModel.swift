import Foundation
import Domain

/// The main "Listening…" screen's brain (docs/ARCHITECTURE.md §6): drives the real
/// capture → analyze → prosody → lyrics → rank pipeline end to end, phrase by phrase.
/// Works identically whether the melody came from a voice or an instrument — the
/// DSP layer only ever sees pitch/onset/amplitude, never the source.
@MainActor
@Observable
final class SessionViewModel {
    enum SessionState: Equatable {
        case idle
        case requestingPermission
        case permissionDenied
        case listening
        case analyzingPhrase
        case suggesting
        case failed(String)
    }

    private(set) var state: SessionState = .idle

    // Live DSP telemetry (throttled to 30 fps per docs/ARCHITECTURE.md §5 UI guidance).
    private(set) var currentPitchHz: Double?
    private(set) var currentAmplitude: Float = 0
    private(set) var currentConfidence: Float = 0
    private(set) var isVoiced = false
    private(set) var currentTempo: TempoEstimate?
    private(set) var liveNoteCountInPhrase = 0
    private(set) var energyHistory: [Float] = []

    // Lyric generation.
    private(set) var currentSpec: PhraseSpec?
    private(set) var rankedCandidates: [RankedCandidate] = []
    private(set) var generationError: String?
    private(set) var sessionMemory = SessionMemory()

    static let energyHistoryCapacity = 150
    static let uiUpdateInterval: TimeInterval = 1.0 / 30.0

    private let services: AppServices
    private var pipelineTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
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
        generationTask?.cancel()
        generationTask = nil
        let capture = services.capture
        Task { await capture.stop() }
        state = .idle
    }

    /// Clears prior-phrase DSP telemetry and any suggestion in flight — song memory
    /// (accepted lines, themes, rejects) is intentionally NOT cleared here; it's the
    /// whole point of continuity across a listening session.
    private func resetTelemetry() {
        lastPitchUIUpdate = -1
        currentPitchHz = nil
        currentAmplitude = 0
        currentConfidence = 0
        isVoiced = false
        currentTempo = nil
        liveNoteCountInPhrase = 0
        energyHistory.removeAll(keepingCapacity: true)
        currentSpec = nil
        rankedCandidates = []
        generationError = nil
    }

    private func run() async {
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
            currentAmplitude = frame.rmsEnergy
            currentConfidence = frame.confidence
            isVoiced = frame.isVoiced
            energyHistory.append(frame.rmsEnergy)
            if energyHistory.count > Self.energyHistoryCapacity {
                energyHistory.removeFirst(energyHistory.count - Self.energyHistoryCapacity)
            }

        case .tempoUpdated(let tempo):
            currentTempo = tempo

        case .phraseInProgress(_, let provisionalNotes):
            liveNoteCountInPhrase = provisionalNotes

        case .phraseCompleted(let phrase):
            handlePhraseCompleted(phrase)
        }
    }

    private func handlePhraseCompleted(_ phrase: Phrase) {
        liveNoteCountInPhrase = 0
        generationTask?.cancel()
        state = .analyzingPhrase
        let spec = services.prosody.spec(for: phrase, tempo: currentTempo, memoryHints: sessionMemory)
        generationTask = Task { [weak self] in await self?.generate(spec: spec) }
    }

    /// The single path every suggestion request goes through — initial generation,
    /// [Regenerate], [More Like This], [Different Emotion], and the +1/−1 syllable
    /// chips all funnel here with a modified `PhraseSpec`. Cancelling the prior task
    /// before starting a new one is the "latest-phrase-wins" supersession
    /// (docs/ARCHITECTURE.md §6); the phraseID guard below covers the case where a
    /// stale task's typed-throw catch block still runs after cancellation.
    private func generate(spec: PhraseSpec) async {
        guard !Task.isCancelled else { return }
        currentSpec = spec
        state = .suggesting
        rankedCandidates = []

        do throws(LyricProviderError) {
            let raw = try await services.lyrics.candidates(for: spec, memory: sessionMemory)
            guard !Task.isCancelled, currentSpec?.phraseID == spec.phraseID else { return }
            rankedCandidates = services.ranker.rank(raw, spec: spec, memory: sessionMemory)
            generationError = nil
        } catch {
            guard !Task.isCancelled else { return }
            generationError = "\(error)"
            state = .listening
        }
    }

    private func restartGeneration(spec: PhraseSpec) {
        generationTask?.cancel()
        generationTask = Task { [weak self] in await self?.generate(spec: spec) }
    }

    private func rejectShownCandidates(reason: RejectedLine.Reason) {
        for ranked in rankedCandidates {
            sessionMemory.rejected.append(RejectedLine(text: ranked.candidate.text, reason: reason))
        }
    }

    // MARK: - User intents (docs/ARCHITECTURE.md §9)

    /// No API call: append the line, fold its emotion into memory, go back to listening.
    func use(_ ranked: RankedCandidate) {
        guard let spec = currentSpec else { return }
        let emotion = spec.topEmotions.first?.emotion ?? sessionMemory.dominantEmotion ?? .reflection
        let line = LyricLine(
            phraseID: spec.phraseID,
            text: ranked.candidate.text,
            stressMap: StressMap(pattern: ranked.candidate.stressAlignment),
            emotion: emotion,
            acceptedAt: Date()
        )
        sessionMemory.acceptedLines.append(line)
        sessionMemory.dominantEmotion = emotion
        generationTask?.cancel()
        generationTask = nil
        currentSpec = nil
        rankedCandidates = []
        generationError = nil
        state = .listening
    }

    func regenerate() {
        guard let spec = currentSpec else { return }
        rejectShownCandidates(reason: .regenerated)
        restartGeneration(spec: spec)
    }

    func moreLikeThis(_ ranked: RankedCandidate) {
        guard let spec = currentSpec else { return }
        restartGeneration(spec: spec.withVariationSeed(ranked.candidate.text))
    }

    func differentEmotion(_ emotion: Emotion) {
        guard let spec = currentSpec else { return }
        rejectShownCandidates(reason: .differentEmotion)
        restartGeneration(spec: spec.withEmotionOverride(emotion))
    }

    func adjustSyllableTarget(by delta: Int) {
        guard let spec = currentSpec else { return }
        restartGeneration(spec: spec.withAdjustedSyllableTarget(by: delta))
    }
}
