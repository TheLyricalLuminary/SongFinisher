#!/usr/bin/env python3
"""Measures SyllableCounter's out-of-vocabulary heuristic against CMUdict ground truth.

The Swift heuristic only ever runs on words the bundled dictionary does not hold, but
the bundled lexicon *is* CMUdict-derived, so it can stand in as a truth set: run the
heuristic over every common word in lexicon.bin and compare against the real count.

Usage:
    python3 tools/verify_syllables.py            # current rule
    python3 tools/verify_syllables.py --compare  # every rule variant, side by side

Method note: a candidate change is only worth taking if it raises exact-match accuracy
here. A first attempt at the "-le" rule fired on any consonant plus "e", turned "shine"
and "grace" into two syllables, and made accuracy *worse* than the original; only this
measurement caught it.
"""

import argparse
import struct
import sys
from pathlib import Path

LEXICON = Path(__file__).resolve().parent.parent / \
    "Packages/LyricEngine/Sources/LyricEngine/Resources/lexicon.bin"

VOWELS = "aeiouy"


def load_words():
    """Yields (word, cmudict_syllable_count) for every alphabetic lexicon entry."""
    data = LEXICON.read_bytes()
    magic, version, n, strings_off, strings_len = struct.unpack_from("<4sIIII", data, 0)
    assert magic == b"SFLX" and version == 1
    cur = 32
    offsets = struct.unpack_from(f"<{n + 1}I", data, cur); cur += (n + 1) * 4
    syl = struct.unpack_from(f"<{n}B", data, cur)
    blob = data[strings_off:strings_off + strings_len]
    out = []
    for i in range(n):
        text = blob[offsets[i]:offsets[i + 1]].decode()
        if text.isalpha():
            out.append((text, syl[i]))
    return out


def vowel_groups(word):
    groups, current = [], []
    for ch in word:
        if ch in VOWELS:
            current.append(ch)
        elif current:
            groups.append(current)
            current = []
    if current:
        groups.append(current)
    return groups


# ── Rule variants ────────────────────────────────────────────────────────────
# Each takes the word and returns a syllable count. `baseline` is what the code
# did before this branch; `current` is what is on disk now.

def baseline(word):
    groups = vowel_groups(word)
    count = len(groups)
    if word.endswith("e") and count > 1 and groups[-1] == ["e"]:
        count -= 1
    return max(1, count)


def le_only(word):
    """The first pass: silent-e and "-ed", with the syllabic l handled on the "-le" side only."""
    groups = vowel_groups(word)
    count = len(groups)
    ends_bare_e = word.endswith("e") and count > 1 and groups[-1] == ["e"]
    if word.endswith("ed") and len(word) > 3 and count > 1 and groups[-1] == ["e"]:
        if word[-3] not in ("t", "d"):
            count -= 1
    elif ends_bare_e:
        count -= 1
        if word.endswith("le") and len(word) >= 3 and word[-3] not in VOWELS:
            count += 1
    return max(1, count)


def has_syllabic_l(word):
    """Mirrors SyllableCounter.hasSyllabicL."""
    if len(word) >= 3 and word[-1] == "e" and word[-2] == "l":
        l_index = len(word) - 2                       # little, gentle
    elif len(word) >= 4 and word[-3:] == "led":
        l_index = len(word) - 3                       # bubbled, handled
    else:
        return False
    if l_index < 1:
        return False
    preceding = word[l_index - 1]
    # A vowel keeps the e silent (whole, style, fueled); a second l means the French /
    # proper-noun "-lle" (belle, Nashville) and its "-led" form (called, filled, pulled).
    return preceding not in VOWELS and preceding != "l"


def current(word):
    """Mirrors SyllableCounter.heuristicStressPattern as it stands on disk."""
    groups = vowel_groups(word)
    count = len(groups)
    ends_bare_e = word.endswith("e") and count > 1 and groups[-1] == ["e"]
    syllabic_l = has_syllabic_l(word)

    if word.endswith("ed") and len(word) > 3 and count > 1 and groups[-1] == ["e"]:
        if word[-3] not in ("t", "d") and not syllabic_l:
            count -= 1
    elif ends_bare_e:
        count -= 1
        if syllabic_l:
            count += 1
    return max(1, count)


VARIANTS = {
    "baseline": baseline,
    "le-only": le_only,
    "current": current,
}


def measure(rule, words):
    exact = off_by_one = worse = 0
    misses = []
    for word, truth in words:
        got = rule(word)
        delta = got - truth
        if delta == 0:
            exact += 1
        elif abs(delta) == 1:
            off_by_one += 1
            misses.append((word, truth, got))
        else:
            worse += 1
            misses.append((word, truth, got))
    total = len(words)
    return {
        "total": total,
        "exact": exact,
        "exact_pct": 100.0 * exact / total,
        "off_by_one_pct": 100.0 * off_by_one / total,
        "worse_pct": 100.0 * worse / total,
        "misses": misses,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--compare", action="store_true", help="measure every variant")
    ap.add_argument("--words", nargs="*", help="just print counts for these words")
    args = ap.parse_args()

    words = load_words()

    if args.words:
        truth = dict(words)
        for w in args.words:
            row = [f"{name}={fn(w)}" for name, fn in VARIANTS.items()]
            print(f"{w:12} cmudict={truth.get(w, '?'):>3}  " + "  ".join(row))
        return 0

    names = list(VARIANTS) if args.compare else ["current"]
    print(f"{len(words)} alphabetic lexicon entries\n")
    print(f"{'rule':<12}{'exact':>9}{'off-by-1':>10}{'worse':>8}")
    for name in names:
        r = measure(VARIANTS[name], words)
        print(f"{name:<12}{r['exact_pct']:>8.1f}%{r['off_by_one_pct']:>9.1f}%"
              f"{r['worse_pct']:>7.1f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
