# Song Finisher — project brief

**Purpose of this document:** a self-contained briefing to hand to an AI assistant (or a new
human collaborator) so it understands what this codebase is, what it does, who it serves, and
— critically — **what is actually built versus what is only designed**. Every claim below was
verified against the source, not copied from the spec.

Companion documents:

- `docs/ARCHITECTURE.md` — the approved design contract. It describes the *intended* end state
  and includes components that do not exist yet. Treat it as the blueprint, not an inventory.
- `docs/BUILDING.md` — how to compile, test, and run on real hardware.
- `docs/APP_STORE_COPY.md` — marketing copy, deliberately constrained to shipped behaviour.
- `ACKNOWLEDGEMENTS.md` — data-source licences for the bundled lexicon.

---

## 1. What Song Finisher is

**Song Finisher is a native iOS/macOS app that listens to you sing, hum, or play guitar,
detects when you finish a musical phrase, and hands you lyric lines built to fit that exact
phrase — its syllable count, stress pattern, tempo, melodic contour, and emotional character.**

The one-line mission, repeated throughout the codebase: *Play a melody. Get lyrics that fit.*

It is deliberately **not**:

- a chatbot or a prompt box,
- a generic "write me a song about heartbreak" lyric generator,
- a recording/DAW app,
- a music transcription tool.

The differentiator is the **constraint**: lyrics are generated against the measured prosody of a
phrase the user *just performed*, and the fit is then re-verified on-device. A line that scans
wrong against the melody is rejected by the app before the user ever sees it, regardless of how
good the language model thought it was.

---

## 2. Who it's for

**Primary user: the working songwriter who gets stuck at the words, not the music.**

The concrete scenario the whole product is shaped around: someone picks up a guitar, plays or
hums a phrase they like, and stalls — the melody is there, the words are not. They do not want a
finished song written for them. They want the next line, or the raw material to write it
themselves, *while they still have the melody in their hands*.

Design consequences that follow from that user, visible all over the code:

| User reality | How the product answers it |
|---|---|
| Flow state is fragile — a spinner or an error modal kills the session | Suggestions resolve locally in milliseconds; generation failures silently fall back rather than showing an error (`FoundationModelsLyricProvider` catches everything except cancellation) |
| They write in rooms with no signal, on planes, in garages | The full experience runs offline. There is no account, no login, no network call in the shipping build |
| Their unfinished songs are private and personal | Live audio is **never** persisted; the only permission requested is the microphone; on Apple Intelligence hardware, generation happens on-device |
| Half of songwriters play chords, not single-note melodies | A polyphony detector routes strummed chords into a rhythm-only path so the app works for players, not just singers |
| A machine can guarantee meter but not meaning | Alongside generated lines, the app offers "sparks" — evocative words and rhymes — so the human can write the line themselves |
| They will notice immediately if a line doesn't scan | Syllables and stress are recounted on-device; the model's own claims are never trusted |

**Secondary audience: Apple's editorial/featuring team.** The project is positioned as a
Foundation Models showcase — a non-chat, structured use of on-device generation. That framing
shapes `docs/APP_STORE_COPY.md` and the on-device-first provider strategy.

**Author context:** built solo. The developer's own hardware is an iPhone 13 (no Apple
Intelligence) plus an Apple Silicon Mac — which is why the offline tier is treated as a
first-class product surface rather than a degraded fallback, and why a macOS target exists.

---

## 3. What it does — the user-facing flow

1. **Open the app.** It goes straight to `SessionView` — the "Listening…" screen. There is no
   song list, no onboarding, no settings.
2. **Tap to listen.** Mic permission is requested inline; denial shows a banner with a Settings
   deep link.
3. **Sing, hum, or play.** Live telemetry updates at 30 fps: a waveform of recent energy, the
   detected tempo, a pitch-confidence dot, a mood badge, and a syllable meter that fills *while
   you perform* so you can see "it heard 6, I sang 7" and re-hum.
4. **Stop.** ~350 ms of silence (or a cadential long note, or a 12 s cap) closes the phrase.
5. **Get suggestions.** The phrase becomes a `PhraseSpec` — syllable budget, stress map
   (`S`/`w` per syllable), tempo, contour, top-3 emotions, per-note durations, long-note slots.
   Candidates are generated against it, re-scored on-device, and shown ranked, with a per-syllable
   stress underline and a provider badge.
6. **Get sparks.** Alongside the card: ~6 evocative words matched to the phrase's emotion and
   meter, plus ~6 rhymes for the last line you kept.
7. **Act.** `[Use]`, `[Regenerate]`, `[More Like This]`, `[Different Emotion ▾]`, `+1 / −1
   syllable` chips, and (for strummed input) a sparse/medium/dense density picker.
8. **Keep going.** Kept lines appear in a strip and feed session memory, which biases subsequent
   suggestions. Rejected lines are remembered too — they teach taste, not just avoidance.

**Important limitation:** session memory is **in-memory only**. Closing the app loses the song.
Nothing is saved to disk today.

---

## 4. How it works — technical shape

### 4.1 The pipeline

```
AVAudioEngine tap (memcpy only)
  → lock-free SPSC ring buffer
  → 16 kHz mono, 10 ms hop / 1024-sample window
  → YIN pitch + spectral-flux onsets + tempo autocorrelation
  → PolyphonyDetector → [melodic path | rhythmic path]
  → NoteSegmenter / RhythmSegmenter → PhraseSegmenter
  → Phrase → ProsodyDeriving → PhraseSpec
  → LyricProviding (Foundation Models | offline assembler)
  → CandidateRanker (deterministic re-scoring)
  → SessionViewModel → SessionView
```

Every stage boundary is an `AsyncStream` of `Sendable` value types. Swift 6 strict concurrency
is on in every target.

### 4.2 Module layout

Dependencies point strictly downward; **SPM manifests enforce the architecture** — `Domain`
physically cannot import SwiftUI because its manifest declares no such dependency.

| Module | Imports | Contains |
|---|---|---|
| `SongFinisher/` (app target) | everything | Composition root only. `AppServices.live()` / `.fakes()` is the single place concrete types are named |
| `Features/` | Domain + SwiftUI | `SessionView` + `SessionViewModel` (the product), `DiagnosticCaptureView` (a DSP debug tool), `RootView` |
| `Packages/Domain` | Foundation only | All models, all service protocols, all pure logic (syllable counter, stress deriver, emotion scorer, ranker, scorers) |
| `Packages/MelodyKit` | Domain, AVFoundation, Accelerate | Capture + DSP. Knows nothing about lyrics |
| `Packages/LyricEngine` | Domain, Foundation | Both lyric providers, the lexicon, the assembler, sparks. Knows nothing about microphones |
| `Packages/PersistenceKit` | Domain, SwiftData | **Stub.** Contains only a marker type today |

`MelodyKit`, `LyricEngine`, and `PersistenceKit` are peers and never import each other. The
`PhraseSpec` is the value that connects DSP to lyrics; the connecting code lives in
`SessionViewModel`.

### 4.3 The DSP layer (`MelodyKit`)

- **Pitch:** YIN (CMNDF), 1024-sample window, 65–1047 Hz, parabolic interpolation, 5-frame
  median filter, voicing hysteresis. YIN's aperiodicity measure is reused three ways: UI
  confidence, voicing gate, and prompt confidence.
- **Onsets:** half-wave-rectified log-magnitude spectral flux with an adaptive median+MAD
  threshold and 50 ms dead time, **fused with pitch-jump onsets** so legato singing (which
  energy flux misses) still segments.
- **Tempo:** autocorrelation of the onset-strength envelope over an 8 s sliding window, 60–200
  BPM, log-Gaussian prior at 105 BPM. Below 0.35 confidence the beat grid is dropped rather than
  asserted.
- **Notes/phrases:** notes open on onset and close on the next onset or on unvoicing; melisma
  (pitch glide without re-articulation) is merged so it consumes one syllable slot. Phrases close
  on silence ≥ 350 ms, a cadential long note, or a 12 s cap. Minimum 2 notes and 700 ms —
  phrases failing that emit `phraseDiscarded` with a reason, so a dropped phrase is
  distinguishable from a boundary that never fired.
- **Hybrid melodic/rhythmic routing:** `PolyphonyDetector` flags hops where ≥ 2 strong spectral
  peaks are inharmonic against YIN's own f0, or where YIN collapses under a dense signal. Votes
  smooth over ~0.5 s (enter ≥ 50%, exit ≤ 15%). In rhythmic mode the pitch path is bypassed and
  `RhythmSegmenter` builds `isRhythmOnly` phrases from the onset pocket; the syllable budget
  becomes onset-count × the user's chosen `SyllableDensity` (1.0× / 1.5× / 2.0×), contour is
  `flat`, and tolerance is never below ±1 because the budget is an estimate by construction.

### 4.4 The lyric layer (`LyricEngine`)

Two concrete conformances of `LyricProviding`, selected once at composition time in
`AppServices.bestAvailableLyricProvider()`:

**Tier 1 — `FoundationModelsLyricProvider`** (iOS 26 / macOS 26, Apple Intelligence hardware).
Uses `LanguageModelSession` with `@Generable` guided output to produce exactly 8 candidate lines
plus self-reported `emotionalFit` and `memorability`. Guided generation means there is no JSON
parsing and no malformed-response path. A fresh stateless session per request; all continuity
travels in the prompt via `SessionMemory`. **Any** failure except cancellation falls back to the
offline provider for that request — a musician mid-flow never sees an error because a guardrail
balked. Entirely behind `#if canImport(FoundationModels)`, so older SDKs compile it to nothing.

**Tier 2 — `OfflineLyricProvider`** (everywhere else, and the universal fallback). Pure
constraint satisfaction, no model:

- A **35k-word bundled lexicon** (`lexicon.bin`, ~894 KB, memory-mapped, custom "SFLX v1"
  binary format) built by `tools/build_lexicon.py` from CMUdict (syllables, stress, vowel
  openness, rhyme keys), Moby POS (part-of-speech bitsets), wordfreq (Zipf frequency), and VADER
  (valence). Licences are documented in `ACKNOWLEDGEMENTS.md`; deliberately-excluded sources
  (EmoLex, Warriner VAD norms, espeak-ng) are listed there too.
- A **template bank** of POS frames ("subject + verb + article + noun", etc.) with closed-class
  literals for subjects, articles, and line-enders.
- **Beam search** (width 12) fills slots left-to-right so the concatenated stress aligns to the
  spec's stress map — output satisfies the meter *by construction*.
- Scoring favours an "evocative" Zipf band (~3.8) so the beam does not collapse onto the most
  common, most clichéd words; a stop-word guard prevents function words from filling content
  slots (this was a real bug — it produced salad like "during your several a").
- **Seeded RNG** keyed on phrase ID, regenerate count, emotion override, and variation seed, so
  Regenerate walks deterministically to fresh candidates and tests are exact-match.
- Contractually never errors and always returns candidates, widening past the phrase's own
  tolerance as a last resort rather than returning empty.

**Sparks — `LexiconSparkProvider`.** A synchronous lexicon lookup, not a generation request.
Returns up to 6 evocative content words (filtered to a Zipf band, capped at 3 per part of speech
so the set mixes nouns/verbs/adjectives, excluding words already used this session) and up to 6
rhymes for the last accepted line's final word. The rationale is explicit in the code: *a
word-level assembler cannot guarantee meaning, so rather than hand the songwriter a nonsense
line, hand them raw material and let them write it.*

### 4.5 Ranking — the trust boundary

`Domain.CandidateRanker` re-scores every candidate on-device across six axes:

| Axis | Weight | Source |
|---|---|---|
| `syllableFit` | 0.30 | On-device recount |
| `stressFit` | 0.25 | On-device lexical stress vs the target stress map |
| `singability` | 0.15 | On-device (open vowels on long notes, consonant-cluster penalties) |
| `emotionalFit` | 0.15 | Model self-report (clamped 0…1), or lexical overlap offline |
| `continuity` | 0.10 | On-device (rhyme-tail match, motif echo, near-verbatim penalty) |
| `memorability` | 0.05 | Model self-report (clamped) |

**70% of the weight is deterministic and computed locally.** `syllableFit < 0.3` is a hard drop —
a budget-violating candidate can never outrank a fitting one. This is the single most important
invariant in the codebase: *the model is never the judge of objective constraints.*

### 4.6 State and concurrency

- All ViewModels are `@MainActor @Observable`, init-injected with protocols, never importing
  service packages.
- `SessionViewModel` state machine: `idle → requestingPermission → listening → analyzingPhrase
  → suggesting → listening`, with **latest-phrase-wins** supersession (in-flight generation is
  cancelled, plus a `phraseID` mismatch guard for stale tasks).
- Isolation domains: audio tap thread (the codebase's only `@unchecked Sendable`, the ring
  buffer) → DSP chain (all mutable state confined) → `@MainActor` → cooperative pool (providers
  are stateless `Sendable` structs).

---

## 5. Current build state — read this before changing anything

### Built and wired into the running app

- Real-time capture and the full DSP chain (pitch, onsets, tempo, note/phrase segmentation,
  vibrato handling, polyphony detection, rhythm-only phrasing).
- `PhraseSpec` derivation for both melodic and rhythm-only phrases.
- Both lyric providers, provider auto-selection, and the offline fallback path.
- Word/rhyme sparks.
- Deterministic ranking.
- `SessionView` — the product screen — with all six user intents.
- In-session memory (accepted lines, rejections, dominant emotion).
- A `DiagnosticCaptureView` DSP debug tool, reachable from a toolbar button.
- iOS and macOS app targets.
- ~165 test cases across the four packages.

### Designed in `docs/ARCHITECTURE.md` but NOT built

Do not assume these exist:

- **Persistence.** `PersistenceKit` contains only a marker type. There is no `SongStore`, no
  SwiftData models, no Keychain store, and no store in `AppServices`. `SongStoring` is an
  unimplemented protocol. **Songs do not survive app launch.**
- **The Claude / remote provider.** `ProviderKind.claude` is an enum case with no implementation.
  `HTTPPerforming` and `APIKeyProviding` are unimplemented protocols. There is **no networking
  code anywhere in the app** — no URLSession call, no API key handling, no `UpgradingLyricProvider`.
  §9 of the architecture doc describes this in detail; it is a design, not a build.
- **Navigation shell.** No `SongListView`, `SongSheetView`, `MemoImportView`, `SettingsView`, or
  `MicPermissionView`. `RootView` goes straight to `SessionView`.
- **Voice Memo Resurrection.** `MelodyAnalyzer.analyzeFile(at:progress:)` is implemented and works,
  but has **no UI entry point**, and its DTW section/hook clustering is stubbed —
  `sections` and `repeatedPhraseGroups` always return empty.
- **Theme/motif harvesting.** `SessionMemory.themes`, `motifs`, `hookLine`, and `rhymeTails`
  exist as fields and are read by scorers, but nothing populates them during a session.
- Live Activity / Dynamic Island, Siri / App Intents, iPad support, and any purchase or
  subscription code.

### Verification status — important

- **No Swift toolchain exists in the cloud environment this code was written in.** Nothing in
  recent history has been compiled by the author's agent.
- **CI has never successfully run.** GitHub Actions has been failing at startup with zero jobs
  since repo creation — Actions is disabled or unbilled at the *account* level, not misconfigured.
  `.github/workflows/ci.yml` is correct and ready (Linux `swift:6.0` container, `Domain` +
  `LyricEngine` suites); it needs the repo owner to enable Actions and set a spending limit.
- Therefore **a Mac is the first real compiler**. `docs/BUILDING.md` covers this. The highest-risk
  file is `FoundationModelsLyricProvider` / `FoundationModelsPromptBuilder`, which calls an API
  that only exists in the iOS 26 / macOS 26 SDK.

**Practical implication for an AI working here:** you probably cannot compile or run the tests.
Do not claim a change builds. Write code conservatively, keep the pure-Swift packages
(`Domain`, `LyricEngine`) toolchain-portable, and say plainly what was and wasn't verified.

---

## 6. Build and test

The Xcode project is generated and intentionally not committed:

```sh
brew install xcodegen        # once
xcodegen generate            # after any project.yml or file-set change
open SongFinisher.xcodeproj
```

Package tests run without Xcode — this is the fastest verification loop:

```sh
swift test --package-path Packages/Domain          # pure Swift, builds anywhere
swift test --package-path Packages/LyricEngine     # pure Swift, builds anywhere
swift test --package-path Packages/MelodyKit       # needs macOS (AVFoundation/Accelerate)
swift test --package-path Packages/PersistenceKit
```

Schemes: `SongFinisher` (iOS, iPhone-only, deployment target 17.0) and `SongFinisherMac`
(macOS 14.0+). The Mac target exists because the iOS Simulator has no route to external audio
interfaces, and because it is the only likely Apple-Intelligence-capable hardware on hand.

---

## 7. Conventions and invariants to respect

1. **The model never judges objective constraints.** Syllables and stress are always recounted
   on-device. Never let a provider's self-reported syllable count reach the ranker.
2. **Layer boundaries are enforced by SPM manifests, not convention.** If an import doesn't
   compile, the architecture is telling you something. Do not add a dependency to a `Package.swift`
   to work around it without deciding that the layering itself should change.
3. **`Domain` imports Foundation only.** No SwiftUI, no AVFoundation, no SwiftData, ever.
4. **Concrete service types are named in exactly one place:** `AppServices`. ViewModels see
   protocols.
5. **Honest degradation over false precision.** Low confidence widens the syllable tolerance
   rather than asserting a wrong number. This pattern recurs — follow it.
6. **Never show the musician an error for a recoverable condition.** Fall back and badge the
   result honestly instead.
7. **Determinism where it's cheap.** The offline path is seeded so tests are exact-match; keep it
   that way.
8. **Privacy is architectural.** Live audio is never written to disk. Do not add analytics,
   accounts, or network calls without an explicit decision.
9. **Comments explain *why*, and cite `docs/ARCHITECTURE.md` sections.** Match that density and
   style; the existing comments carry real reasoning, not restatement.
10. **Don't claim unbuilt features** in docs, App Store copy, or code comments. There is an
    explicit "do NOT claim these yet" list in `docs/APP_STORE_COPY.md` for exactly this reason.

---

## 8. Highest-value next steps

Roughly in order of what unblocks the most:

1. **Enable GitHub Actions** (account-level setting + spending limit) so the logic layer gets a
   green check on every push. Nothing else in the project is blocked on a decision this small.
2. **Compile on a Mac** and fix whatever the first real build surfaces — most likely the
   Foundation Models call sites.
3. **Persistence.** `PersistenceKit` is the largest gap between the app and something a
   songwriter can rely on. Losing a session on app close is the most user-visible flaw today.
4. **Theme/motif harvesting**, so session memory actually sharpens across a session rather than
   only accumulating lines.
5. **Navigation shell** (song list → session → song sheet), which persistence makes meaningful.
6. **Voice Memo Resurrection UI** — the analysis path already works; it needs an entry point and
   the DTW clustering.
