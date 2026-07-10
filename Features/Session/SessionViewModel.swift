import Foundation
import Domain

/// The main "Listening…" screen (docs/ARCHITECTURE.md §6). State machine:
/// `idle → listening → analyzingPhrase → suggesting → (accept | regenerate | …) → listening`,
/// with latest-phrase-wins supersession: any in-flight generation is cancelled the moment
/// a newer phrase completes or the current spec is re-requested, guarded by both
/// cooperative cancellation and a `phraseID` match check. Mirrors
/// `DiagnosticCaptureViewModel`'s permission/lifecycle handling, then layers the
/// prosody → lyrics → ranking pipeline on top of each completed phrase.
@MainActor
@Observable
final class SessionViewModel {
    enum State: Equatable {
        case idle
        case requestingPermission
        case permissionDenied
        case listening
        case analyzingPhrase
        case suggesting
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var tempo: TempoEstimate?
    private(set) var liveSyllableCount = 0
    private(set) var currentPhrase: Phrase?
    private(set) var currentSpec: PhraseSpec?
    private(set) var ranked: [RankedCandidate] = []
    private(set) var acceptedLines: [LyricLine] = []
    private(set) var memory = SessionMemory()
    private(set) var generationError: LyricProviderError?
    /// What the DSP chain currently hears: a melodic line, or strummed chords (the
    /// rhythm-only fallback, where the syllable budget comes from the onset pocket).
    private(set) var inputMode: InputMode = .melodic
    /// Syllables-per-strum for rhythm-only phrases; ignored for melodic ones.
    private(set) var density: SyllableDensity = .medium

    private let services: AppServices
    private var pipelineTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
    }

    // MARK: - Lifecycle

    func start() {
        guard pipelineTask == nil else { return }
        pipelineTask = Task { [weak self] in await self?.run() }
    }

    /// Stops capture and discards in-flight work. Safe to call from `.onDisappear` /
    /// a non-active scene phase (deinit-based cancellation is unreliable for
    /// `@Observable` view models) as well as from an explicit "pause listening" tap.
    func stop() {
        pipelineTask?.cancel()
        pipelineTask = nil
        generationTask?.cancel()
        generationTask = nil
        let capture = services.capture
        Task { await capture.stop() }
        state = .idle
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
            // The stream can end on its own (e.g. a test double that finishes
            // immediately), not just via stop()'s cancellation.
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
        case .pitch:
            break // raw pitch telemetry lives in DiagnosticCaptureView, not this screen
        case .tempoUpdated(let estimate):
            tempo = estimate
        case .phraseInProgress(_, let provisionalNotes):
            liveSyllableCount = provisionalNotes
        case .phraseCompleted(let phrase):
            beginSuggesting(for: phrase)
        case .inputModeChanged(let mode):
            inputMode = mode
        }
    }

    // MARK: - Suggestion pipeline

    private func beginSuggesting(for phrase: Phrase) {
        currentPhrase = phrase
        ranked = []
        generationError = nil
        liveSyllableCount = 0
        state = .analyzingPhrase
        let spec = services.prosody.spec(for: phrase, tempo: tempo, memoryHints: memory, density: density)
        request(spec, phraseID: phrase.id)
    }

    /// The single place a generation request is issued — cancels any earlier in-flight
    /// request for this phrase (regenerate / more-like-this / different-emotion / ±1
    /// syllable all funnel through here) before starting the new one.
    private func request(_ spec: PhraseSpec, phraseID: UUID) {
        currentSpec = spec
        state = .suggesting
        generationTask?.cancel()
        generationTask = Task { [weak self] in
            await self?.generate(spec, phraseID: phraseID)
        }
    }

    private func generate(_ spec: PhraseSpec, phraseID: UUID) async {
        guard !Task.isCancelled else { return }
        do throws(LyricProviderError) {
            let candidates = try await services.lyrics.candidates(for: spec, memory: memory)
            guard !Task.isCancelled, currentPhrase?.id == phraseID else { return }
            ranked = services.ranker.rank(candidates, spec: spec, memory: memory)
        } catch {
            guard !Task.isCancelled, currentPhrase?.id == phraseID else { return }
            if error != .cancelled { generationError = error }
            ranked = []
        }
    }

    // MARK: - User intents

    func accept(_ candidate: LyricCandidate) {
        guard let spec = currentSpec, candidate.phraseID == spec.phraseID else { return }
        let emotion = spec.requestedEmotionOverride ?? spec.topEmotions.first?.emotion ?? .reflection
        let line = LyricLine(
            phraseID: candidate.phraseID,
            text: candidate.text,
            stressMap: StressMap(pattern: candidate.stressAlignment, noteToSyllable: spec.budget.stressMap.noteToSyllable),
            emotion: emotion,
            acceptedAt: Date()
        )
        memory = SessionMemoryUpdater.accepting(line, into: memory)
        acceptedLines.append(line)
        resetSuggestion()
    }

    /// Explicit reject with no regeneration — clears the card so the singer can move on.
    func dismiss(_ candidate: LyricCandidate) {
        memory = SessionMemoryUpdater.rejecting(candidate.text, reason: .explicitReject, into: memory)
        resetSuggestion()
    }

    func regenerate() {
        guard let spec = currentSpec else { return }
        if let top = ranked.first?.candidate {
            memory = SessionMemoryUpdater.rejecting(top.text, reason: .regenerated, into: memory)
        }
        request(spec, phraseID: spec.phraseID)
    }

    func moreLikeThis(_ candidate: LyricCandidate) {
        guard let spec = currentSpec else { return }
        memory = SessionMemoryUpdater.rejecting(candidate.text, reason: .regenerated, into: memory)
        request(spec.withVariationSeed(candidate.text), phraseID: spec.phraseID)
    }

    func requestDifferentEmotion(_ emotion: Emotion) {
        guard let spec = currentSpec else { return }
        if let top = ranked.first?.candidate {
            memory = SessionMemoryUpdater.rejecting(top.text, reason: .differentEmotion, into: memory)
        }
        request(spec.withEmotionOverride(emotion), phraseID: spec.phraseID)
    }

    func adjustSyllableTarget(by delta: Int) {
        guard let spec = currentSpec else { return }
        if let top = ranked.first?.candidate {
            memory = SessionMemoryUpdater.rejecting(top.text, reason: .regenerated, into: memory)
        }
        request(spec.withAdjustedSyllableTarget(by: delta), phraseID: spec.phraseID)
    }

    /// The sparse/medium/dense selector for strummed input. When a rhythm-only phrase
    /// is on screen its spec is re-derived at the new density and re-requested — the
    /// singer is telling us the current suggestion has the wrong number of syllables
    /// per strum, so a stale card would be worse than a fresh request.
    func setDensity(_ newDensity: SyllableDensity) {
        guard newDensity != density else { return }
        density = newDensity
        guard let phrase = currentPhrase, phrase.isRhythmOnly else { return }
        if let top = ranked.first?.candidate {
            memory = SessionMemoryUpdater.rejecting(top.text, reason: .regenerated, into: memory)
        }
        let spec = services.prosody.spec(for: phrase, tempo: tempo, memoryHints: memory, density: newDensity)
        request(spec, phraseID: phrase.id)
    }

    private func resetSuggestion() {
        currentPhrase = nil
        currentSpec = nil
        ranked = []
        generationError = nil
        state = pipelineTask == nil ? .idle : .listening
    }
}
