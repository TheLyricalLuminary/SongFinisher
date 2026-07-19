# Building & verifying Song Finisher

None of the recent work has been compiled by CI (GitHub Actions is blocked at the
account level — see the last section) or in the cloud environment it was written in
(no Swift toolchain there). Your Mac is the first real compiler. This guide gets you
from a fresh checkout to a running app, fastest-verification-first.

## 1. Verify the logic in ~2 minutes (no app build, no Xcode project)

The four feature packages are plain Swift Package Manager modules. You can compile and
test each straight from Terminal — no `.xcodeproj`, no simulator, no iOS 26 SDK. This
is the quickest way to catch compile errors and confirm the logic that actually ships
to every device.

```sh
cd SongFinisher
swift test --package-path Packages/Domain
swift test --package-path Packages/LyricEngine   # syllable logic, ranker, word-salad guard, sparks
swift test --package-path Packages/MelodyKit      # DSP: pitch, onsets, phrase + chord segmentation
swift test --package-path Packages/PersistenceKit
```

- `Domain` and `LyricEngine` are pure Swift (Foundation only) — they build anywhere.
- `MelodyKit` imports AVFoundation/Accelerate, so it needs macOS (you have it).
- If any of these fail to **compile**, that's the highest-signal feedback you can send
  me — paste the error output verbatim and I'll fix it. A test that compiles but
  *fails* is also useful: it means the logic is wrong somewhere specific.

## 2. Build & run the app

The Xcode project is generated from `project.yml` by XcodeGen (it's intentionally not
committed):

```sh
brew install xcodegen        # once
xcodegen generate            # regenerate SongFinisher.xcodeproj whenever project.yml or files change
open SongFinisher.xcodeproj
```

Then in Xcode:

- **iPhone 13 (your phone) — the offline experience.** Select the `SongFinisher`
  scheme and your device, run. This is the constraint-based offline generator plus the
  new word "sparks." No Apple Intelligence; this is what most users will see.
- **Mac (Apple Silicon, macOS 26) — the on-device AI experience.** Select the
  `SongFinisherMac` scheme. If the Mac is Apple-Intelligence-capable, the Foundation
  Models provider activates and writes full lines; otherwise it falls back to the same
  offline path. This is the only hardware you likely own that can run the AI tier —
  your iPhone 13 cannot.

## 3. Known unverified spots (where a first build is most likely to break)

- **`FoundationModelsLyricProvider` / `FoundationModelsPromptBuilder`** — these call
  Apple's Foundation Models API (`LanguageModelSession`, `@Generable`, `@Guide`,
  `SystemLanguageModel.availability`). That API only exists in the iOS 26 / macOS 26
  SDK (Xcode 26). On older Xcode the whole file compiles to nothing (it's behind
  `#if canImport(FoundationModels)`), so the offline build is unaffected. On Xcode 26,
  if the API names have shifted, this is the most likely place to see errors — paste
  them and I'll correct the call sites.
- Everything else (chord/rhythm DSP, phrase-discard reporting, the salad guard, sparks)
  is ordinary Swift and should be caught by the `swift test` runs in step 1.

## 4. Turn CI back on (only you can do this)

Every GitHub Actions run since the repo was created has failed at startup with zero
jobs — Actions is disabled or unbilled at the account level, not broken in the config.
Once you fix that, the Linux workflow already in `.github/workflows/ci.yml` will run
the `Domain` + `LyricEngine` suites automatically on every push and give you a green
check on the logic layer.

1. **Repo → Settings → Actions → General** → set *Actions permissions* to
   "Allow all actions and reusable workflows".
2. **Account → Settings → Billing and licensing → Spending limit** → because the repo
   is private, add a payment method and set a spending limit (Linux minutes are cheap
   and the free tier covers a lot; this just has to be configured, not large).

Push any commit afterward and confirm the run goes green instead of
`startup_failure`.
