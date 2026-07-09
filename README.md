# Song Finisher

*Play a melody. Get lyrics that fit.*

A native iOS melody-to-lyric copilot: sing, hum, or play a phrase and get lyric
suggestions that match its rhythm, syllable count, stress pattern, and emotional
character — live, phrase by phrase.

- **Platform:** iOS 17+, Swift 6, SwiftUI, MVVM
- **Architecture:** see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

## Project layout

| Path | What it is |
|---|---|
| `SongFinisher/` | App target (composition root only) |
| `Features/` | SwiftUI views + `@Observable` ViewModels |
| `Packages/Domain` | Models, service protocols, pure logic — imports Foundation only |
| `Packages/MelodyKit` | Real-time audio capture + DSP (YIN pitch, onsets, tempo, phrases) |
| `Packages/LyricEngine` | Claude provider, offline provider, ranking pipeline |
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
