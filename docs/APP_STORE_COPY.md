# App Store copy — accurate to the build

Every claim here is grounded in what the code actually does today (verified against the
source, not the earlier marketing draft). The point is to be *undeniable* to an Apple
reviewer: they check, and a single false claim about frameworks or capabilities costs
you credibility with the exact editorial team you're pitching. Placeholders in
`[brackets]` are facts only you can supply or verify.

---

## What the app genuinely does (the honest feature list)

- Real-time listening + DSP on-device: pitch (YIN), onsets (spectral flux), tempo, and
  note/phrase segmentation. Detects when you finish a musical phrase — **from voice or
  guitar**.
- Detects strummed chords (polyphony) and switches to a rhythm-based phrasing mode, so
  it works for singers *and* players.
- Derives a "fit" spec for each phrase: syllable count, stress pattern (strong/weak),
  tempo, melodic contour, and a mood read from an 8-emotion acoustic classifier.
- Writes lyric candidates that fit that spec:
  - **On Apple Intelligence devices:** on-device generation with the Foundation Models
    framework (`LanguageModelSession` + `@Generable`). Nothing leaves the device.
  - **On every other device:** a built-in constraint engine over a 35k-word bundled
    lexicon (CMUdict + Moby part-of-speech + word frequency + VADER sentiment). Fully
    offline, works in airplane mode.
  - Both paths **recount syllables and stress on-device**, so the model is never trusted
    to fake a fit.
- Offers word + rhyme **"sparks"** — evocative words that fit the phrase's feeling and
  meter, plus rhymes for your last line — when you'd rather write the line yourself.
- Remembers the lines you keep and reject **within a session**, plus your themes, and
  folds them into the next suggestion.
- Native SwiftUI on **iPhone and Mac**.

## Do NOT claim these yet — they are not built

Claiming an absent feature to Apple is the fastest way to lose editorial trust. Build
these first, then add them back to the copy:

- **Live Activity / Dynamic Island** — not implemented.
- **Siri / App Intents** — not implemented.
- **Saving songs across app launches** — session memory is in-memory only right now; it
  is lost when the app closes. "Remembers within a session" is true; "saves your songs"
  is not yet.
- **iPad** — the iOS target is iPhone-only today (add the iPad device family first).
- **Subscription / freemium tiers** — no purchase code exists.

---

## Nomination (App Store Connect → Featuring)

**Type:** App Launch

**Nomination name** (internal, ≤60):
`Song Finisher — Launch (on-device phrase-to-lyric)`

**Description** (≤1000 chars):

> Song Finisher listens while you sing or play guitar, detects each completed musical
> phrase in real time, and writes lyric lines built to fit that exact phrase — its
> syllable count, stress pattern, tempo, melodic contour, and mood.
>
> On Apple Intelligence devices it generates those lines entirely on-device with the
> Foundation Models framework (LanguageModelSession + @Generable): no account, no
> network, works in airplane mode. On every other device a built-in engine keeps it
> fully functional offline. Both paths recount syllables and stress on-device, so a
> suggested line always fits the melody — the model is never trusted to fake it.
>
> It reads voice and strummed chords alike, remembers the lines you keep and reject as
> the session grows, and offers evocative word and rhyme "sparks" when you'd rather
> write the line yourself.
>
> Native SwiftUI on iPhone and Mac. Built solo by [Mark Amigoni — welder and signed
> songwriter; verify bio]. Launching [DATE].

**Helpful details** (context, don't repeat the description):

> - Foundation Models showcase: real-time DSP builds a structured `@Generable` prompt
>   (syllables, stress, contour, emotion) — a clean, non-chat use of on-device generation.
> - Private by architecture: on-device generation, no account, airplane-mode capable.
> - Honest degradation: a built-in offline engine keeps the app fully usable on hardware
>   without Apple Intelligence, so nothing is a dead end.
> - Novel core: constraining generated lyrics to the measured stress map of a
>   just-performed phrase (voice or guitar) is the differentiator.
> - Contact: [your contact]. TestFlight and a demo video available on request.

---

## Product page

**App name** (≤30): `Song Finisher: Lyrics`

**Subtitle** (≤30) — pick one:
- `Finish what you just played` (honest, leads with the phrase-detection magic)
- `Lyrics that fit your melody`

**Promotional text** (≤170):

> Play or sing a line — Song Finisher hears when you land a phrase and helps you finish
> it with lyrics that fit its rhythm and feel. On-device and private. Best on Apple
> Intelligence devices.

**Description** (≤4000):

> You just played something good. Now finish it.
>
> Song Finisher listens while you sing or play guitar, hears when you land a complete
> musical phrase, and helps you finish it — with lyric ideas built to fit the rhythm,
> stress, tempo, and mood of exactly what you just played.
>
> HOW IT WORKS
> • Play or sing a phrase.
> • Song Finisher detects the finished phrase and reads its rhythm, stress, and shape.
> • You get lyric ideas that fit that phrase — and evocative words and rhymes to write
>   your own line from.
> • Keep the ones you love, reject the ones you don't — it remembers both as the session
>   grows and gets sharper.
>
> BUILT FOR REAL SESSIONS
> • Works with voice or guitar — it even detects strummed chords and follows the groove.
> • Keeps a running memory of your kept lines, rejects, and themes during a session.
> • Native on iPhone and Mac.
>
> PRIVATE BY DESIGN
> On Apple Intelligence devices, the lyric model runs entirely on your device — no
> account, no cloud, and it works in airplane mode. On other devices a built-in engine
> keeps everything working offline. Your unfinished songs stay on your phone.
>
> BEST ON APPLE INTELLIGENCE DEVICES
> The full on-device songwriting model runs on Apple Intelligence hardware (iPhone 15
> Pro and later, and Apple silicon Mac). On earlier devices Song Finisher still runs
> with a built-in generator and its word-and-rhyme sparks — lighter, but never a dead
> end.
>
> From [the author of "The Song Finisher" — verify]. Grab your guitar. Play the line.
> Let's finish it.

**Keywords** (≤100, no spaces after commas, singular, no words from the name):

> lyric,songwriting,melody,write,guitar,singer,verse,chorus,rhyme,music maker,compose,voice,idea

---

## Honesty checklist before you submit

- [ ] Every feature named above still exists in the shipping build (re-check after any
      refactor).
- [ ] The founder bio, book, label, and any placements are accurate and verifiable.
- [ ] You have personally used the flagship (Apple Intelligence) experience on real
      hardware — screenshots and the demo video must show the real app.
- [ ] Nothing in the "Do NOT claim yet" list has crept back into the copy.
