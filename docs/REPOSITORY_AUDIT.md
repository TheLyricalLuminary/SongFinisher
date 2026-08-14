# REPOSITORY_AUDIT.md — Song Finisher

**Source of truth:** `TheLyricalLuminary/SongFinisher` @ `main`, HEAD `bb2fe3f3e5573f731b4fe46e86cf259bf19f7af9` (2026-08-04), cloned directly via `git clone` and read byte-for-byte. Gate A (retrieval) and Gate B (audit) are **complete**. Every classification below cites file and line.

**Evidence classes used throughout:** VERIFIED · EXTERNAL EVIDENCE · HYPOTHESIS · REQUIRES LOCAL MEASUREMENT · UNVERIFIED (TOOL-ACCESS). Nothing in this document is UNVERIFIED — the tool-access blocker is resolved. Discrepancy headers additionally carry verdict labels (CONTRADICTS_DOCUMENTATION · VERIFIED CLEAN · PARTIAL) layered on top of these evidence classes.

---

## Discrepancies (a)–(j) — resolved

### (a) Ring buffer: "lock-free" claim vs `OSAllocatedUnfairLock` — **CONTRADICTS_DOCUMENTATION (doc is stale; code is honest)**
- `docs/ARCHITECTURE.md:13` claims "AVAudioEngine tap → **lock-free** ring buffer"; `docs/ARCHITECTURE.md:71` labels it "RingBuffer (SPSC)".
- `Packages/MelodyKit/Sources/MelodyKit/RingBuffer.swift:7-13` explicitly documents the opposite, with rationale: `OSAllocatedUnfairLock` "rather than true lock-free atomics" because `Synchronization.Atomic` needs an iOS 18 floor and the project targets iOS 17 (all four `Package.swift` files — Domain, MelodyKit, LyricEngine, PersistenceKit: `.iOS(.v17), .macOS(.v14)`; `project.yml:22` `IPHONEOS_DEPLOYMENT_TARGET: "17.0"`). The comment notes unfair-lock **priority donation** protects the tap thread from inversion, and names the upgrade path ("swap to Atomic<Int> when the deployment floor rises").
- Critical section (`RingBuffer.swift:38-49, 55-63`): index arithmetic + a scalar per-sample copy loop. Producer side ≤ 1024 floats/tap callback (tap `bufferSize: 1024`); consumer side ≤ ~4,800 floats (100 ms drain block at 48 kHz). Bounded, no reentrancy, no allocation. Overflow drops oldest and increments a `dropped` counter (`RingBuffer.swift:40-43`) readable via `droppedSampleCount` (`:32`).
- **Verdict:** fix the two doc lines; do not touch the implementation absent profiling evidence (see Matrix Q1).

### (b) Channel handling: mono-fold comment vs channel-0 read — **CONTRADICTS_DOCUMENTATION (comment is wrong; behavior is channel-0)**
- `AudioCaptureService.swift:56` comment: "Tap discipline: **mono-fold** + copy into the ring." `:59` implementation: `ring.write(channels[0], count: frames)` — channel 0 only, no fold.
- Consequence by input type: built-in mic (mono) — identical; stereo USB/audio interface — right channel silently discarded. Session options (`:40`) are `.playAndRecord, .measurement, [.defaultToSpeaker, .allowBluetoothA2DP]` — **no `.allowBluetooth` (HFP)**, so Bluetooth *microphones* are never selected as input; only BT *output* is allowed. That keeps pitch analysis off 8/16 kHz HFP mics — defensible, but nowhere documented as a decision.
- **Verdict:** either implement the fold or fix the comment; document the no-HFP-input choice explicitly.

### (c) 5 ms buffer assumed vs read back — **PARTIAL, low risk**
- `AudioCaptureService.swift:41` calls `setPreferredIOBufferDuration(0.005)`; the actual `ioBufferDuration` is never read back. However `:49-52` **does** read back the true hardware format (`inputFormat(forBus: 0)`) and guards `sampleRate > 0, channelCount > 0`; the tap, ring (~8 s capacity, `:24`), and 100 ms drain blocks (`:127`) are all sized off the read-back rate, so nothing depends on 5 ms being honored. The preferred-duration call is effectively a latency hint (consistent with Apple QA1631: preferences are hints — EXTERNAL EVIDENCE).
- **Verdict:** correct-by-construction; optionally log the effective `ioBufferDuration` for diagnostics.

### (d) Disallowed work inside the tap — **VERIFIED CLEAN (one deliberate lock)**
- `AudioCaptureService.swift:55-60`: guard, `frameLength` read, `ring.write`. No allocation, no logging, no `await`, no graph mutation. The single unfair-lock acquisition is the documented design tradeoff from (a).

### (e) PhraseSpec fields — **VERIFIED; one claimed field MISSING, one present but unconsumed (corrected)**
- Present (`Packages/Domain/Sources/Domain/Models/PhraseSpec.swift:6-20`): `phraseID`, `budget` (→ `SyllableBudget`: target, tolerance, stressMap), `emotions`, `tempoBPM`, `tempoConfidence`, `contourShape`, `noteDurationsMs`, `longNoteSlots`, `phraseDuration`, `requestedEmotionOverride`, `variationSeedText`, `chord: ChordEstimate?` (documented as "bonus signal, not a requirement", `:17-19`). Re-request mutators exist: `withVariationSeed`, `withEmotionOverride`, `withAdjustedSyllableTarget` (`:54-84`).
- **PRESENT BUT UNCONSUMED (correction — previously misreported as missing):** `noteToSyllable` exists. `StressMap.swift:13` declares `public let noteToSyllable: [Int]` ("melisma notes collapse into their predecessor's slot"), populated in production by `StressMapDeriver.swift:15,37` and `RhythmProsodyDeriver.swift:37-60`, reachable as `PhraseSpec.budget.stressMap.noteToSyllable`. The actual gap is a **consumer**: `FoundationModelsPromptBuilder.swift:44-45` and `PhraseAssembler.swift:110` read only `.pattern`, never `.noteToSyllable`.
- **MISSING:** a `cadence` field. Nuance: cadence *exists as a boundary rule* in `PhraseSegmenter.swift:5,11-15` (silence ≥ 350 ms; cadence path: final note ≥ 1.5× running duration + ≥ 150 ms quiet; min phrase 0.7 s) — it just isn't propagated into the spec the AI layer sees.

### (f) CandidateRanker dimensions, weights, threshold, LLM confinement — **VERIFIED**
- `Packages/Domain/Sources/Domain/Logic/CandidateRanker.swift:7-8`: `dropThreshold = 0.3` on `syllableFit`; `syllableErrorPenalty = 0.35` per syllable beyond tolerance (`:49-55`). `stressFitScore` = fraction of Strong slots agreeing (`:60-71`).
- Weights (`Packages/Domain/Sources/Domain/Models/LyricScore.swift:30-35`): syllable 0.30, stress 0.25, singability 0.15, emotionalFit 0.15, continuity 0.10, memorability 0.05.
- Model scores confined to the two subjective axes only — `CandidateRanker.swift:27-35` and `FoundationModelsLyricProvider.swift:61-79` (syllables/stress recounted on-device via `SyllableCounter` for every model line). **The "LLM never judges objective fit" rule holds in code.**
- Minor doc-comment drift: `LyricScore.swift:3-4` says objective axes "carry 70%"; the arithmetic is 80% deterministic (0.30+0.25+0.15+0.10) vs 20% model-sourced. Fix the comment.

### (g) SessionViewModel cancellation + stale rejection — **VERIFIED**
- `Features/Session/SessionViewModel.swift:230,281`: `generationTask?.cancel()` before every new generation; `:268`: `guard !Task.isCancelled, currentSpec?.phraseID == spec.phraseID else { return }` — the phraseID guard the critique described, with a comment (`:248-249`) referencing ARCHITECTURE §6 supersession. Pipeline teardown cancels both tasks (`:110-113`).

### (h) Cloud/.claude provider removal — **PARTIAL (client gone, scaffolding remains)**
- No HTTP client file exists in `Packages/LyricEngine/Sources/` (verified against the full tree). Remaining residue: `Domain/Services/HTTPPerforming.swift`, `Domain/Services/APIKeyProviding.swift` (`anthropicKey()`), `LyricCandidate.swift:7-8` `case claude` ("designed as an optional future provider; not shipped"), UI badge branches `Features/Session/SuggestionCardView.swift:136-140, 152`, and stale doc `ARCHITECTURE.md:160` (`ProviderKind { claude, offline }` — missing the shipped `.appleIntelligence`). No `URLSession` use in production code.
- **Verdict:** decide keep-as-seam vs delete; either way update ARCHITECTURE §9/§4.
- **Status (2026-08-13):** branch `claude/generic-lyrics-ew8chh` (uncommitted) has already executed the delete — `HTTPPerforming.swift`, `APIKeyProviding.swift`, `case claude`, and both badge branches are gone. `ARCHITECTURE.md` §9 and the `ProviderKind` snippet at `:160` are untouched; the doc-update half of the decision remains open.

### (i) Concurrency audit — **VERIFIED: small, disciplined surface**
- `@unchecked Sendable` ×2, both documented: `RingBuffer.swift:14` (named in ARCH §10 as the codebase's one; now two) and `AudioCaptureService.swift:10-12` (all mutable state behind `stateLock`).
- `nonisolated(unsafe)` ×5, all in synchronous AVAudioConverter feed closures (`AudioCaptureService.swift:152-153`, `MelodyAnalyzer.swift:121-123`) — safe pattern (closure invoked synchronously within `convert(to:)`).
- `Task.detached` ×1 (`MelodyAnalyzer.swift:15`, `.userInitiated`, cancellation-checked, chain state confined by construction). Actors ×2 (correction): `PersistenceKit/SongStore.swift:14` (production) and `FakeSongStore` (`SongFinisher/Fakes.swift:35`) — compiled into the app target per `project.yml` sources, though its doc comment notes it is never used in `.live()`. Drain runs on a dedicated `Thread` at `.userInteractive` (`AudioCaptureService.swift:72-76`).

### (j) PersistenceKit — verified `SongStore` is an actor conforming to `SongStoring`; memory snapshots persisted fire-and-forget from the ViewModel (`SessionViewModel.swift:311`). Migration plan: not present (single schema). Classify **PARTIAL** pending a versioned-schema decision before any model change ships.

---

## Findings beyond (a)–(j)

1. **Interruption/route-change handling: MISSING repo-wide.** Zero matches for `interruptionNotification` / `routeChangeNotification` in the entire tree. A phone call, headphone unplug, or route switch stops capture with no detection or recovery path. This is the highest-priority code gap (Matrix Q2) and intersects the known iOS `installTap`-after-interruption regression (EXTERNAL EVIDENCE).
2. **Foundation Models "architecture A" is not a proposal — it is the shipped implementation.** `FoundationModelsLyricProvider.swift:36-45`: fresh `LanguageModelSession` per request, continuity carried in the prompt via `SessionMemory` ("no conversation state to keep", `:38-40`). `SessionMemory` + `SessionMemoryUpdater` mean option C's bounded-memory component already exists deterministically. The A/B/C benchmark's burden of proof reverses: B/C must beat shipped A.
3. **Candidate count 8 is hard-coded in the generation contract:** `@Guide(… .count(8))` (`FoundationModelsLyricProvider.swift:90`). The 4/6/8/10/12 sweep requires parameterizing that guide.
4. **`prewarm()` is never called** (zero matches). Cheapest known latency lever before any speculative-generation work.
5. **Failure policy verified (refined):** any non-cancellation, non-`LyricProviderError` generation error (guardrail, context overflow, model unloaded) silently falls back to `OfflineLyricProvider`, badged `.offline` — a middle catch rethrows Domain-typed `LyricProviderError` rather than falling back (`FoundationModelsLyricProvider.swift:15-18, 55-58`). Availability gated via `SystemLanguageModel.default.availability` (`:31-34`); everything `#if canImport(FoundationModels)` + `@available(iOS 26, macOS 26)` over an iOS 17 floor.
6. **Offline-file analysis path exists — the CI enabler is real:** `MelodyAnalyzer.analyzeFile(at:)` decodes any AVAudioFile-readable format to 16 kHz mono and runs the *identical* `AnalysisChain` faster than real time (`MelodyAnalyzer.swift:5-6, 28-37`). Mic capture, memo file, and test fixture share one chain by design.
7. **CI reality:** `.github/workflows/ci.yml` runs only Domain + LyricEngine in a `swift:6.0` Linux container; its own comment says MelodyKit/app need macOS and that macOS runners weren't available "for the account" while the repo was private. **The repo is now public → GitHub-hosted macOS runners are free for public repos** — the historical blocker is gone. MelodyKit imports AVFoundation, so it can never run on Linux; the macOS job is the only route.
8. **Lexicon reproducibility gap located:** `tools/build_lexicon.py` fully documents sources (CMUdict 0.7b BSD-2, Moby POS public-domain, wordfreq/SUBTLEX, VADER MIT), the SFLX v1 binary format byte-for-byte, and admission rules (a–z' only, ≤ 12 syllables, Zipf ≥ 2.5 with a Moby POS tag, or Zipf ≥ 3.5 tagless). **But `tools/data/` and the pinned `.venv` are not checked in** — the inputs, not the script, are what's missing. **Correction:** at `bb2fe3f` the shipped `lexicon.bin` has received **no** POS fix — its history holds only the initial build (`c54c1eb`) and one full script-driven regeneration adding the cluster field (`4f4ad72`). Commit `095cbca` added a POS-tagging fix to `build_lexicon.py` that its own message says needs a rebuild to take effect; an *in-place* fix (`tools/filter_lexicon_pos.py` + modified `lexicon.bin`) exists only as uncommitted work beyond this snapshot. A fresh build from re-downloaded sources still diverges (unpinned inputs). The SFLX header makes a vocabulary-diff script trivial (Matrix Q5).
9. **Doc drift inventory (ARCHITECTURE.md vs code):** §1:13 "lock-free" (see a); §8:323 "vDSP polyphase FIR" resample vs actual `AVAudioConverter` (`AudioCaptureService.swift:118-125`); §4:160 `ProviderKind` missing `.appleIntelligence`; §10 "one `@unchecked Sendable`" vs two. None are code bugs; all are spec-truth bugs. Fix in one doc pass.
10. **Melisma test coverage (recounted):** 9 mentions across 3 files — `SegmentationTests.swift` (3), `TempoAndProsodyTests.swift` (1, an explanatory comment), and `StressMapDeriverTests.swift` (5, including the dedicated `melismaNotesDoNotEarnTheirOwnSlot()`, the most substantive melisma test in the repo, already running in Linux CI via the Domain package). `VibratoTests.swift` covers vibrato separately. The thin spot is MelodyKit-layer melisma on real audio — real-singing fixtures (Gate D) remain the gap; current fixtures are synthesized `TestSignals`.

---

## Errata (2026-08-13 verification pass)

All 127 checkable claims in this document and RESEARCH_VALIDATION_MATRIX.md were independently re-verified against `bb2fe3f` (10 parallel verifiers; each disputed claim adversarially re-checked). Result: 98 accurate · 19 partial · 1 inaccurate · 9 external. Corrections applied above:

- **(e):** `noteToSyllable` was misreported as missing — it exists (`StressMap.swift:13`), is populated in production, and lacks only a consumer.
- **Finding 8 / Q5:** the "post-build in-place POS fix" was back-dated from uncommitted work outside this audit's snapshot; at `bb2fe3f` the shipped binary carries no POS fix.
- **Finding 10 / Gate D:** melisma count corrected from 4 (audit) / 3 (matrix) to 9 across 3 files; `StressMapDeriverTests.swift` was omitted despite holding the most substantive melisma test.
- **(i):** actor census corrected from one to two (`FakeSongStore` compiles into the app target).
- **Finding 5:** fallback rule refined — `LyricProviderError` is rethrown, not swallowed into fallback.
- **(h):** status note added — branch `claude/generic-lyrics-ew8chh` already executes the delete decision; the ARCHITECTURE §9/:160 doc update remains open.
