import Foundation
import Domain

/// The main "Listening…" screen's brain (docs/ARCHITECTURE.md §6): drives the real
/// capture → analyze → prosody → lyrics → rank pipeline end to end, phrase by phrase.
/// Works identically whether the melody came from a voice or an instrument — the
/// DSP layer only ever sees pitch/onset/amplitude, never the source. Strummed chords
/// are detected as polyphonic input and routed through the rhythm-only fallback: the
/// syllable budget then comes from the onset grid scaled by the singer's chosen
/// density rather than from pitch.
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
    private(set) var currentChord: ChordEstimate?
    private(set) var liveNoteCountInPhrase = 0
    private(set) var energyHistory: [Float] = []
    /// What the DSP chain currently hears: a melodic line, or strummed chords (the
    /// rhythm-only fallback, where the syllable budget comes from the onset pocket).
    private(set) var inputMode: InputMode = .melodic
    /// Syllables-per-strum for rhythm-only phrases; ignored for melodic ones.
    private(set) var density: SyllableDensity = .medium

    // Lyric generation.
    private(set) var currentPhrase: Phrase?
    private(set) var currentSpec: PhraseSpec?
    private(set) var rankedCandidates: [RankedCandidate] = []
    /// Evocative words + rhymes for the current phrase — the songwriter's raw material
    /// when the generated line isn't the one. Resolved locally and instantly.
    private(set) var currentSparks: WordSparks?
    /// Which engine wrote the lines most recently shown. The session screen leads with
    /// sparks rather than the card on the offline tier, and reading the *last* engine
    /// rather than the one currently running keeps that layout stable across the gap
    /// while the next generation is in flight. Seeded from the composed provider so the
    /// first phrase of a session is already laid out right.
    private(set) var lastProviderKind: ProviderKind
    /// True while a request is actually in flight. Without this, "still working" and
    /// "finished and found nothing" are the same state on screen — an empty candidate
    /// list — and the suggestion card's spinner would run with nothing coming. Providers
    /// throw rather than return empty, so the remaining way to land there is the ranker
    /// dropping every candidate below its quality threshold.
    private(set) var isGenerating = false
    private(set) var generationError: String?
    private(set) var sessionMemory = SessionMemory()
    /// True once a generation in this session was routed to the offline engine because
    /// the free tier's daily premium budget ran out — drives the upsell banner. Sticky
    /// for the rest of the session (going Pro mid-session clears it via the next check).
    private(set) var didHitFreeLimit = false

    /// Lock and move (the method from "The Song Finisher", as an app mode): with flow
    /// mode on, every line is written onto the song sheet as it arrives. Taking your
    /// hands off the instrument to tap [Use] is what breaks a flow state, so the app
    /// records what you played and leaves curation for afterwards — one line per phrase,
    /// replaced if you regenerate, and [Undo keep] takes back the last one.
    /// Persisted: a writer who works this way always works this way.
    var isFlowMode: Bool {
        didSet { UserDefaults.standard.set(isFlowMode, forKey: Self.flowModeKey) }
    }

    private static let flowModeKey = "session.flowMode"

    static let energyHistoryCapacity = 150
    static let uiUpdateInterval: TimeInterval = 1.0 / 30.0

    private let services: AppServices
    /// The saved song this session writes into. `nil` = ephemeral session (tests /
    /// previews); when set, accepted lines and memory are persisted best-effort.
    private let songID: UUID?
    /// Shown on the Live Activity (lock screen / Dynamic Island) while listening.
    private let songTitle: String
    /// `nil` = unmetered (tests, previews, diagnostics): every generation uses the
    /// premium provider. The live app passes `ProStore`.
    private let gating: (any GenerationGating)?
    private let liveActivity = SessionActivityController()
    private var pipelineTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var lastPitchUIUpdate: TimeInterval = -1

    init(
        services: AppServices,
        songID: UUID? = nil,
        songTitle: String? = nil,
        initialMemory: SessionMemory = SessionMemory(),
        gating: (any GenerationGating)? = nil
    ) {
        self.services = services
        self.songID = songID
        self.songTitle = songTitle ?? "New Song"
        self.sessionMemory = initialMemory
        self.gating = gating
        self.isFlowMode = UserDefaults.standard.bool(forKey: Self.flowModeKey)
        // `AppServices` already picked the best available engine at composition time, so
        // on hardware without Apple Intelligence the screen can lay itself out correctly
        // before the first phrase instead of reordering once the first draft lands.
        self.lastProviderKind = services.lyrics.kind
    }

    func start() {
        guard pipelineTask == nil else { return }
        resetTelemetry()
        // Warm the generation model while the writer is still settling in front of
        // the mic. Foundation Models lazy-loads on first use, and without this the
        // session's very first phrase pays that cost as seconds of suggestion
        // spinner — a cold start indistinguishable from a hang.
        let lyrics = services.lyrics
        Task { await lyrics.prewarm() }
        pipelineTask = Task { [weak self] in await self?.run() }
    }

    func stop() {
        pipelineTask?.cancel()
        pipelineTask = nil
        generationTask?.cancel()
        generationTask = nil
        let capture = services.capture
        Task { await capture.stop() }
        liveActivity.end()
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
        currentChord = nil
        liveNoteCountInPhrase = 0
        energyHistory.removeAll(keepingCapacity: true)
        inputMode = .melodic
        currentPhrase = nil
        currentSpec = nil
        rankedCandidates = []
        currentSparks = nil
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
            liveActivity.start(songTitle: songTitle)
            for await event in services.analyzer.analyze(chunks) {
                if Task.isCancelled { break }
                handle(event)
            }
            if !Task.isCancelled {
                state = .idle
                liveActivity.end()
                pipelineTask = nil
            }
        } catch {
            if !Task.isCancelled {
                state = .failed("\(error)")
                liveActivity.end()
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

        case .chordUpdated(let chord):
            currentChord = chord

        case .phraseInProgress(_, let provisionalNotes):
            liveNoteCountInPhrase = provisionalNotes

        case .phraseCompleted(let phrase):
            handlePhraseCompleted(phrase)

        case .phraseDiscarded:
            // The segmenter reset its accumulator; without this the live meter shows
            // the dropped phrase's stale note count until the next phrase starts.
            liveNoteCountInPhrase = 0

        case .inputModeChanged(let mode):
            inputMode = mode
        }
    }

    private func handlePhraseCompleted(_ phrase: Phrase) {
        liveNoteCountInPhrase = 0
        // Nothing to commit here any more: in flow mode a line is kept the moment it
        // arrives (see `generate`), not when the next phrase pushes it off screen. That
        // ordering is what made the song sheet stay empty for anyone who played a phrase
        // and then stopped to look at it.
        currentPhrase = phrase
        generationTask?.cancel()
        state = .analyzingPhrase
        updateLiveActivity(phase: .analyzing)
        let spec = services.prosody.spec(
            for: phrase, tempo: currentTempo, memoryHints: sessionMemory,
            density: density, chord: currentChord
        )
        // Sparks are a local lexicon lookup, not a generation request — resolve them
        // synchronously so the songwriter always has material even while (or if) the
        // line generator produces something weak.
        currentSparks = services.sparks.sparks(for: spec, memory: sessionMemory)
        generationTask = Task { [weak self] in await self?.generate(spec: spec) }
    }

    /// The single path every suggestion request goes through — initial generation,
    /// [Regenerate], [More Like This], [Different Emotion], the +1/−1 syllable chips,
    /// and the rhythm density picker all funnel here with a modified `PhraseSpec`.
    /// Cancelling the prior task before starting a new one is the "latest-phrase-wins"
    /// supersession (docs/ARCHITECTURE.md §6); the phraseID guard below covers the
    /// case where a stale task's typed-throw catch block still runs after cancellation.
    private func generate(spec: PhraseSpec) async {
        guard !Task.isCancelled else { return }
        currentSpec = spec
        state = .suggesting
        rankedCandidates = []
        isGenerating = true
        // The previous attempt's message must not outlive it. Without this a [Regenerate]
        // after a no-fit phrase shows "No line fits that phrase" over the spinner for the
        // whole of the next request — an error about a phrase that is no longer on screen.
        generationError = nil

        // Free tier: each generation event (initial, regenerate, more-like-this, syllable
        // nudge) spends one premium credit. Out of credits → the offline engine, whose
        // cards badge themselves OFFLINE DRAFT, so the downgrade is always visible.
        let usePremium = gating?.allowPremiumGeneration() ?? true
        if !usePremium {
            didHitFreeLimit = true
            // Known before the request even runs, so the layout settles now rather than
            // reordering under the writer's eyes when the draft lands.
            lastProviderKind = .offline
        }
        let provider = usePremium ? services.lyrics : services.offlineLyrics

        do throws(LyricProviderError) {
            let raw = try await provider.candidates(for: spec, memory: sessionMemory)
            guard !Task.isCancelled, currentSpec?.phraseID == spec.phraseID else { return }
            isGenerating = false
            rankedCandidates = services.ranker.rank(raw, spec: spec, memory: sessionMemory)
            // The premium provider falls back internally on ineligible hardware, so the
            // candidate itself is the only honest report of which engine actually ran.
            lastProviderKind = rankedCandidates.first?.candidate.provider ?? lastProviderKind
            // An empty pool is not an error the provider throws — it just returns nothing
            // — so it has to be reported here or it reads as an unending wait.
            generationError = rankedCandidates.isEmpty
                ? "No line fits that phrase. Try playing a longer one, or nudge the syllable count."
                : nil
            // Keep it the moment it exists. A songwriter mid-take shouldn't have to do
            // anything for the song to be recorded — the sheet is what they played, and
            // pruning is a job for afterwards. `commitAccepted` keys on the phrase, so a
            // regenerate for this same phrase rewrites its line instead of adding one.
            if isFlowMode, let top = rankedCandidates.first {
                commitAccepted(top)
            }
            updateLiveActivity(phase: .suggesting)
        } catch {
            guard !Task.isCancelled else { return }
            isGenerating = false
            generationError = "\(error)"
            state = .listening
            updateLiveActivity(phase: .listening)
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
        syncMemoryToStore()
    }

    // MARK: - Persistence (best-effort; a failed write never disrupts the writing flow)

    /// The tail of the write chain. Every store write links onto it, so writes reach the
    /// store in the order the songwriter made them.
    private var persistenceTail: Task<Void, Never>?

    /// Enqueues a store write behind every write already issued.
    ///
    /// These are deliberately fire-and-forget — a persistence error is non-fatal to a live
    /// session (docs/ARCHITECTURE.md §12 — `persistenceFailed` degrades silently rather
    /// than interrupting) — but "don't wait for it" is not the same as "don't order it".
    /// Independent `Task {}` blocks reach the store actor in whatever order the scheduler
    /// picks: `SongStore` serializes each call, not the sequence of them. In flow mode the
    /// writer's phrases arrive fast enough for that to matter twice over. A regenerate's
    /// `replaceLine` could overtake the `append` that created the line, find nothing to
    /// replace, and return silently — leaving the rewritten line in `SessionMemory` and the
    /// superseded one on disk. And each write carries a `SessionMemory` snapshot taken when
    /// it was issued, so an older task landing last would overwrite newer memory with
    /// staler memory.
    ///
    /// Awaiting the previous task fixes both: the chain is FIFO by construction, and the
    /// last snapshot written is the last one taken.
    private func enqueuePersistence(
        _ work: @escaping @Sendable (any SongStoring) async -> Void
    ) {
        let store = services.store
        let previous = persistenceTail
        persistenceTail = Task {
            await previous?.value
            await work(store)
        }
    }

    private func persistAcceptedLine(_ line: LyricLine) {
        guard let songID else { return }
        let memorySnapshot = sessionMemory
        enqueuePersistence { store in
            try? await store.append(line: line, to: songID)
            try? await store.updateMemory(memorySnapshot, songID: songID)
        }
    }

    /// Swaps a phrase's stored line for its replacement, in place. Remove-then-append
    /// would work but would move the rewritten line to the end of the song, so the saved
    /// sheet and its export would disagree with the order the writer watched being built
    /// — `SessionMemory.record` keeps the position, and this has to match it.
    private func persistReplacement(of replaced: LyricLine, with line: LyricLine) {
        guard let songID else { return }
        let memorySnapshot = sessionMemory
        enqueuePersistence { store in
            try? await store.replaceLine(id: replaced.id, with: line, in: songID)
            try? await store.updateMemory(memorySnapshot, songID: songID)
        }
    }

    private func syncMemoryToStore() {
        guard let songID else { return }
        let memorySnapshot = sessionMemory
        enqueuePersistence { store in
            try? await store.updateMemory(memorySnapshot, songID: songID)
        }
    }

    // MARK: - User intents (docs/ARCHITECTURE.md §9)

    /// No API call: append the line, fold its emotion into memory, go back to listening.
    func use(_ ranked: RankedCandidate) {
        guard currentSpec != nil else { return }
        commitAccepted(ranked)
        generationTask?.cancel()
        generationTask = nil
        currentPhrase = nil
        currentSpec = nil
        rankedCandidates = []
        currentSparks = nil
        generationError = nil
        state = .listening
        updateLiveActivity(phase: .listening)
    }

    /// Records a line on the song sheet and persists it. Shared by the explicit [Use]
    /// tap and the automatic keep, so both paths record identically — only the
    /// surrounding state handling differs.
    ///
    /// One line per phrase. [Regenerate], [More Like This], [Different Emotion] and the
    /// syllable nudges all produce a new line for the *same* phrase, so they replace
    /// that phrase's entry rather than stacking another copy; an explicit [Use] on a
    /// line already kept automatically is likewise not a second line. Without this,
    /// keeping automatically would turn every retry into a duplicate on the sheet.
    private func commitAccepted(_ ranked: RankedCandidate) {
        guard let spec = currentSpec else { return }
        let emotion = spec.topEmotions.first?.emotion ?? sessionMemory.dominantEmotion ?? .reflection
        let line = LyricLine(
            phraseID: spec.phraseID,
            text: ranked.candidate.text,
            stressMap: StressMap(pattern: ranked.candidate.stressAlignment),
            emotion: emotion,
            acceptedAt: Date()
        )
        sessionMemory.dominantEmotion = emotion
        if let replaced = sessionMemory.record(line) {
            persistReplacement(of: replaced, with: line)
        } else {
            persistAcceptedLine(line)
        }
    }

    /// Takes back the most recently kept line without interrupting capture — the safety
    /// net that keeps flow mode's automatic keeping non-destructive. Bound to a keyboard
    /// shortcut so it works from a foot pedal mid-take.
    func undoLastAccepted() {
        guard let removed = sessionMemory.acceptedLines.popLast() else { return }
        sessionMemory.dominantEmotion = sessionMemory.acceptedLines.last?.emotion
        if let songID {
            let memorySnapshot = sessionMemory
            // Through the chain like every other write: undo is the case that needs the
            // ordering most, since a delete that overtakes the append it undoes would
            // leave the taken-back line on disk permanently.
            enqueuePersistence { store in
                try? await store.removeLine(id: removed.id, from: songID)
                try? await store.updateMemory(memorySnapshot, songID: songID)
            }
        }
        updateLiveActivity(phase: currentActivityPhase)
    }

    private var currentActivityPhase: SessionActivityPhase {
        switch state {
        case .analyzingPhrase: .analyzing
        case .suggesting: .suggesting
        default: .listening
        }
    }

    private func updateLiveActivity(phase: SessionActivityPhase) {
        liveActivity.update(
            phase: phase,
            acceptedLineCount: sessionMemory.acceptedLines.count,
            lastAcceptedLine: sessionMemory.acceptedLines.last?.text
        )
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

    /// The sparse/medium/dense selector for strummed input. When a rhythm-only phrase
    /// is on screen its spec is re-derived at the new density and re-requested — the
    /// singer is telling us the current suggestion has the wrong number of syllables
    /// per strum, so a stale card would be worse than a fresh request.
    func setDensity(_ newDensity: SyllableDensity) {
        guard newDensity != density else { return }
        density = newDensity
        guard let phrase = currentPhrase, phrase.isRhythmOnly else { return }
        rejectShownCandidates(reason: .regenerated)
        let spec = services.prosody.spec(for: phrase, tempo: currentTempo, memoryHints: sessionMemory, density: newDensity)
        restartGeneration(spec: spec)
    }
}
