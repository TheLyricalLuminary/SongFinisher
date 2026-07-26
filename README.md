# Song Finisher

*Play a melody. Get lyrics that fit.*

A native iOS melody-to-lyric copilot: sing, hum, or play a phrase and get lyric
suggestions that match its rhythm, syllable count, stress pattern, and emotional
character — live, phrase by phrase.

- **Platform:** iOS 17+, Swift 6, SwiftUI, MVVM
- **Orientation:** [docs/PROJECT_BRIEF.md](docs/PROJECT_BRIEF.md) — what this is, who it's for,
  and what is built vs. only designed. Start here (and hand this one to an AI assistant).
- **Architecture:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — the design contract, which
  describes the intended end state, not the current inventory.

## Project layout

| Path | What it is |
|---|---|
| `SongFinisher/` | App target (composition root only) |
| `Features/` | SwiftUI views + `@Observable` ViewModels |
| `Packages/Domain` | Models, service protocols, pure logic — imports Foundation only |
| `Packages/MelodyKit` | Real-time audio capture + DSP (YIN pitch, onsets, tempo, phrases) |
| `Packages/LyricEngine` | Foundation Models (on-device) provider, offline provider, ranking pipeline |
| `Packages/PersistenceKit` | SwiftData store (quarantined), Keychain |

## Building

The Xcode project is generated — it is not checked in:

```sh
brew install xcodegen   # once
xcodegen generate
open SongFinisher.xcodeproj
```

Package tests run without Xcode:

```sh
for p in Domain MelodyKit LyricEngine PersistenceKit; do
  swift test --package-path "Packages/$p"
done
```
