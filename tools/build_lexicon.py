#!/usr/bin/env python3
"""Builds the packed lexicon blob for the OfflineLyricProvider (Phase 4 Task 1).

Three permissively-licensed pillars (see ACKNOWLEDGEMENTS.md):
  - CMUdict 0.7b (BSD-2-Clause)     -> pronunciation, syllables, stress, vowel openness
  - Moby Part-of-Speech (public domain) -> POS tags
  - wordfreq (SUBTLEX et al., documented permission) -> Zipf frequency filter
  - VADER lexicon (MIT)             -> valence

SFLX binary format v1 (little-endian):
  Header (32 bytes):
    magic       4s   "SFLX"
    version     u32  1
    wordCount   u32
    stringsOff  u32  byte offset of the strings blob
    stringsLen  u32
    reserved    12 bytes (zero)
  Parallel arrays, each wordCount entries, contiguous in this order:
    stringOffsets u32[wordCount+1]  (word i = strings[off[i]:off[i+1]])
    syllables     u8
    stressBits    u16  bit i (LSB-first) = syllable i carries PRIMARY stress
    openBits      u16  bit i = syllable i nucleus is an open vowel
    posBits       u16  POS bitset (see POS_BITS)
    zipf          u8   round(zipf * 20)
    valence       i8   round(vader_mean * 25), clamped to [-100, 100]
    rhymeKey      u32  FNV-1a of final vowel + coda phonemes (stress digits stripped)
  Strings blob: UTF-8 concatenated lowercase words, sorted ascending (binary-searchable).

Vocabulary admission: CMUdict base pronunciation, a-z' only, <= 12 syllables,
Zipf >= 2.5, and a Moby POS tag (or Zipf >= 3.5 for tagless very-common words,
which keeps contractions Moby lacks).
"""

import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent / ".venv/lib/python3.11/site-packages"))
from wordfreq import zipf_frequency  # noqa: E402

DATA = Path(__file__).parent / "data"
OUT = Path(__file__).parent.parent / "Packages/LyricEngine/Sources/LyricEngine/Resources/lexicon.bin"

MIN_ZIPF = 2.5
NO_POS_MIN_ZIPF = 3.5
MAX_SYLLABLES = 12

VOWELS = {"AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY",
          "IH", "IY", "OW", "OY", "UH", "UW"}
# Open/singable nuclei for long-note slots (low F1 / jaw-open; spec section 1).
# EH is mid-open and OY starts open; both kept closed-side conservatively per spec text.
OPEN_VOWELS = {"AA", "AE", "AO", "AH", "AW", "AY", "EY", "OW", "ER"}

# Moby POS codes -> bit positions. The Gutenberg mobypos.txt delimiter is a backslash
# (some Moby distributions use \xd7 instead — verify per copy).
POS_BITS = {
    "N": 0,   # noun
    "p": 1,   # plural noun
    "V": 2, "t": 2, "i": 2,   # verb (participle / transitive / intransitive)
    "A": 3,   # adjective
    "v": 4,   # adverb
    "C": 5,   # conjunction
    "P": 6,   # preposition
    "!": 7,   # interjection
    "r": 8,   # pronoun
    "D": 9, "I": 9,   # definite / indefinite article
    "h": 10,  # noun phrase
}


def parse_cmudict(path):
    entries = {}
    with open(path, encoding="latin-1") as f:
        for line in f:
            if line.startswith(";;;"):
                continue
            parts = line.strip().split("  ")
            if len(parts) != 2:
                continue
            word, phones = parts
            if "(" in word:          # alternate pronunciations: keep the base only
                continue
            word = word.lower()
            if not all(c.isalpha() or c == "'" for c in word):
                continue
            entries[word] = phones.split()
    return entries


def parse_moby_pos(path):
    tags = {}
    with open(path, encoding="latin-1") as f:
        for line in f:
            line = line.strip()
            if "\\" not in line:
                continue
            word, codes = line.rsplit("\\", 1)
            word = word.lower()
            bits = 0
            for c in codes:
                if c in POS_BITS:
                    bits |= 1 << POS_BITS[c]
            if bits:
                tags[word] = tags.get(word, 0) | bits
    return tags


def parse_vader(path):
    valence = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.split("\t")
            if len(parts) >= 2:
                try:
                    valence[parts[0].lower()] = float(parts[1])
                except ValueError:
                    pass
    return valence


def analyze(phones):
    """(syllables, stressBits, openBits, rhymeKey) from an ARPAbet sequence.

    R-colored diphthong merge: an unstressed ER0 directly after AY/AW does not earn
    its own syllable ("fire" F AY1 ER0 and "hour" AW1 ER0 sing as one syllable —
    the pinned policy). Known tradeoff: "higher"-class words compress too; sung
    lyrics favor the single-note reading.
    """
    syllables = 0
    stress_bits = 0
    open_bits = 0
    last_vowel_index = -1
    previous_base = None
    for i, ph in enumerate(phones):
        base = ph.rstrip("012")
        if base in VOWELS:
            if ph == "ER0" and previous_base in ("AY", "AW"):
                previous_base = base
                last_vowel_index = i
                continue
            if ph.endswith("1"):
                stress_bits |= 1 << syllables
            if base in OPEN_VOWELS:
                open_bits |= 1 << syllables
            syllables += 1
            last_vowel_index = i
            previous_base = base
        else:
            previous_base = base
    # Rhyme key: final vowel + coda, stress digits stripped (FNV-1a 32-bit).
    rhyme_key = 0x811C9DC5
    if last_vowel_index >= 0:
        for ph in phones[last_vowel_index:]:
            for b in ph.rstrip("012").encode():
                rhyme_key = ((rhyme_key ^ b) * 0x01000193) & 0xFFFFFFFF
    return syllables, stress_bits, open_bits, rhyme_key


def main():
    cmu = parse_cmudict(DATA / "cmudict-0.7b")
    moby = parse_moby_pos(DATA / "mobypos.txt")
    vader = parse_vader(DATA / "vader_lexicon.txt")
    print(f"sources: cmudict={len(cmu)} moby={len(moby)} vader={len(vader)}")

    rows = []
    for word, phones in cmu.items():
        zipf = zipf_frequency(word, "en")
        if zipf < MIN_ZIPF:
            continue
        pos = moby.get(word, 0)
        if pos == 0 and zipf < NO_POS_MIN_ZIPF:
            continue
        syllables, stress, open_bits, rhyme = analyze(phones)
        if not 1 <= syllables <= MAX_SYLLABLES:
            continue
        zipf_q = min(255, round(zipf * 20))
        val_q = max(-100, min(100, round(vader.get(word, 0.0) * 25)))
        rows.append((word, syllables, stress, open_bits, pos, zipf_q, val_q, rhyme))

    rows.sort(key=lambda r: r[0])
    print(f"admitted: {len(rows)} words")

    strings = b"".join(r[0].encode() for r in rows)
    offsets = []
    acc = 0
    for r in rows:
        offsets.append(acc)
        acc += len(r[0].encode())
    offsets.append(acc)

    n = len(rows)
    body = bytearray()
    body += struct.pack(f"<{n + 1}I", *offsets)
    body += struct.pack(f"<{n}B", *(r[1] for r in rows))
    body += struct.pack(f"<{n}H", *(r[2] for r in rows))
    body += struct.pack(f"<{n}H", *(r[3] for r in rows))
    body += struct.pack(f"<{n}H", *(r[4] for r in rows))
    body += struct.pack(f"<{n}B", *(r[5] for r in rows))
    body += struct.pack(f"<{n}b", *(r[6] for r in rows))
    body += struct.pack(f"<{n}I", *(r[7] for r in rows))

    strings_off = 32 + len(body)
    header = struct.pack("<4sIIII12x", b"SFLX", 1, n, strings_off, len(strings))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(header + bytes(body) + strings)
    print(f"wrote {OUT} ({OUT.stat().st_size:,} bytes)")

    # Acceptance self-checks (Task 1).
    idx = {r[0]: r for r in rows}
    b = idx["beautiful"]
    assert b[1] == 3, f"beautiful syllables {b[1]}"
    assert b[2] == 0b001, f"beautiful stress {b[2]:b}"        # 1-0-0, LSB = first syllable
    assert b[3] == 0b110, f"beautiful openness {b[3]:b}"      # UW closed, AH open, AH open
    for w in ["fire", "light", "night", "love", "don't", "i'm", "the", "waiting"]:
        assert w in idx, f"missing expected word: {w}"
    assert idx["fire"][1] == 1
    assert idx["waiting"][1] == 2 and idx["waiting"][2] == 0b01
    # Rhyme: light/night share a key; light/love must not.
    assert idx["light"][7] == idx["night"][7]
    assert idx["light"][7] != idx["love"][7]
    print("self-checks passed")


if __name__ == "__main__":
    main()
