#!/usr/bin/env python3
"""Check LexiconSparkProvider's guarantees against the real bundled lexicon.

A Swift toolchain isn't available everywhere this repo gets worked on (and CI has
never run — see .github/workflows/ci.yml). This is the spark-side companion to
offline_engine_replica.py: it reads Resources/lexicon.bin and reproduces
`LexiconSparkProvider.imageWords`, so the properties the Swift tests assert can be
checked, and the actual word panels eyeballed, without building anything.

The stop-word, profanity and trigger-word sets are parsed out of the Swift sources
rather than copied here, so this always checks what actually ships.

    python3 tools/verify_sparks.py
"""
import re
import sys
import pathlib

REPO = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))
from offline_engine_replica import LexiconStore, SeededRandom, swift_shuffle  # noqa: E402

SRC = REPO / "Packages/LyricEngine/Sources/LyricEngine"


def swift_string_set(path, name):
    """Pull `static let <name>: Set<String> = [ ... ]` out of a Swift source file."""
    m = re.search(rf"static let {name}: Set<String> = \[(.*?)\]", path.read_text(), re.S)
    assert m, f"{name} not found in {path.name}"
    return set(re.findall(r'"([^"]+)"', m.group(1)))


ASM = SRC / "PhraseAssembler.swift"
TRG = SRC / "TriggerWords.swift"

STOP = swift_string_set(ASM, "contentSlotStopWords")
EXCLUDED = swift_string_set(ASM, "excludedContentWords")
STATES = {n: swift_string_set(TRG, n) for n in
          ["joyfulRelease", "heartbreakHold", "tensionSpiral", "hopeReturn", "finalResolve"]}

# Mirrors TriggerWordBank.words(for:) and PhraseAssembler.targetValence(for:).
EMOTION_STATE = {
    "joy": "joyfulRelease", "release": "joyfulRelease",
    "melancholy": "heartbreakHold", "longing": "heartbreakHold", "nostalgia": "heartbreakHold",
    "tension": "tensionSpiral", "hope": "hopeReturn", "reflection": "finalResolve",
}
TARGET_VALENCE = {"joy": 3.0, "hope": 2.5, "release": 1.5, "nostalgia": -0.5,
                  "reflection": -0.25, "longing": -1.0, "tension": -1.5, "melancholy": -2.5}
EMOTIONS = list(TARGET_VALENCE)

# POSCategory.contentWord: noun, pluralNoun, verb, adjective, adverb, interjection.
CONTENT_WORD = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 7)

MIN_ZIPF, MAX_ZIPF, PEAK = 2.8, 5.0, 3.6
MAX_SYLL, IMAGE_COUNT, MAX_PER_POS = 3, 6, 3


def servable(e):
    """The guard imageWords applies before a word can be scored at all."""
    return (1 <= e.syllables <= MAX_SYLL
            and MIN_ZIPF <= e.zipf <= MAX_ZIPF
            and (e.pos & CONTENT_WORD)
            and e.text not in STOP
            and e.text not in EXCLUDED
            and len(e.text) > 1
            and e.text.isalpha())


def image_words(store, emotion, seed, shuffle_curated=True):
    """Port of LexiconSparkProvider.imageWords. `shuffle_curated=False` reproduces the
    earlier ranked-with-a-bonus behaviour, kept so the turnover claim stays falsifiable."""
    target = TARGET_VALENCE[emotion]
    triggers = STATES[EMOTION_STATE[emotion]]
    rng = SeededRandom(seed)
    curated, statistical = [], []
    for e in store.entries:
        if not servable(e):
            continue
        key = e.pos & CONTENT_WORD
        if e.text in triggers:
            curated.append((e.text, key))
        else:
            statistical.append((e.text, key, -abs(e.valence - target) - abs(e.zipf - PEAK)))
    if shuffle_curated:
        swift_shuffle(curated, rng)
    else:
        curated.sort(key=lambda t: -(-abs(store.lookup(t[0]).valence - target)
                                     - abs(store.lookup(t[0]).zipf - PEAK)))
    statistical.sort(key=lambda t: -t[2])

    out, per_pos, used = [], {}, set()
    for text, key in curated + [(t, k) for t, k, _ in statistical]:
        if len(out) >= IMAGE_COUNT:
            break
        if text in used or per_pos.get(key, 0) >= MAX_PER_POS:
            continue
        per_pos[key] = per_pos.get(key, 0) + 1
        used.add(text)
        out.append(text)
    return out


def emotion_seed(emotion, phrase_seed):
    """Mirror of `LexiconSparkProvider.seed(for:memory:emotion:)`'s emotion mixing.

    Swift XORs the phrase seed with an FNV-1a hash of a string carrying the emotion;
    reproducing the hash exactly matters less here than reproducing the *property* —
    that two emotions sharing a curated pool get different seeds.
    """
    h = 0xCBF29CE484222325
    for byte in f"sparks:{phrase_seed}:{emotion}".encode():
        h = ((h ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def main():
    store = LexiconStore(SRC / "Resources/lexicon.bin")
    print(f"lexicon {len(store.entries)} entries · {len(STOP)} stop · {len(EXCLUDED)} excluded\n")

    failures = []
    panels = {}
    for emotion in EMOTIONS:
        eligible = {e.text for e in store.entries
                    if servable(e) and e.text in STATES[EMOTION_STATE[emotion]]}
        # Mirrors LexiconSparkProvider.seed(for:memory:emotion:), which mixes the
        # emotion into the phrase seed. Passing a bare constant here would make every
        # emotion shuffle identically and hide the defect this file exists to catch.
        panel = image_words(store, emotion, seed=emotion_seed(emotion, 42))
        turnover = set().union(*[set(image_words(store, emotion, seed=emotion_seed(emotion, s)))
                                 for s in range(1, 9)])
        frozen = set().union(*[set(image_words(store, emotion, seed=emotion_seed(emotion, s),
                                               shuffle_curated=False))
                               for s in range(1, 9)])
        panels[emotion] = panel

        print(f"{emotion:<11} curated-pool={len(eligible):<3} "
              f"turnover={len(turnover):<3} (ranked-order would be {len(frozen)})")
        print(f"  panel: {panel}")

        # curatedTriggerWordsHeadTheImageSet
        if eligible and not (set(panel) & eligible):
            failures.append(f"{emotion}: no curated word surfaced")
        # imagesNeverSurfaceProfanityOrSingleLetters
        bad = [w for w in turnover if w in EXCLUDED or len(w) <= 1]
        if bad:
            failures.append(f"{emotion}: profanity/single letter surfaced {bad}")
        # curatedSparksTurnOverAcrossASession
        if len(eligible) >= 15 and len(turnover) < 12:
            failures.append(f"{emotion}: only {len(turnover)} distinct across 8 phrases")

    # emotionsSharingACuratedPoolStillDiffer: the book's five states cover the app's
    # eight emotions, so melancholy/longing/nostalgia draw on one pool and joy/release
    # on another. The session screen offers a "Different Emotion" control, so those
    # pairs must still yield different panels or the control visibly does nothing.
    print()
    for a, b in [(x, y) for i, x in enumerate(EMOTIONS) for y in EMOTIONS[i + 1:]
                 if EMOTION_STATE[x] == EMOTION_STATE[y]]:
        if panels[a] == panels[b]:
            failures.append(f"{a}/{b}: share a curated pool and produced identical panels")
        else:
            print(f"{a} vs {b}: {len(set(panels[a]) ^ set(panels[b]))} of "
                  f"{len(panels[a])} words differ")

    print()
    for f in failures:
        print("FAIL", f)
    print("all spark properties hold" if not failures else f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
