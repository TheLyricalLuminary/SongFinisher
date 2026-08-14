#!/usr/bin/env python3
"""Strips part-of-speech tags from non-dictionary words in an existing lexicon blob.

Why this exists rather than a rebuild
-------------------------------------
Moby tags proper nouns and abbreviations as ordinary parts of speech: "russ" and
"hindu" as nouns, "mc", "le" and "rica" as nouns. They are frequent enough to sit
near the top of every Zipf-sorted bucket, so the beam search reaches them first and
the assembler emits lines like "there's the russ hug" and "we support the ly".
Frequency cannot separate them from real vocabulary — "le" has a higher Zipf (4.50)
than "ache" (3.43). Dictionary membership can.

`build_lexicon.py` now applies the same filter at build time, but the shipped
`lexicon.bin` is **not reproducible** from the currently checked-in sources: it holds
35,346 words while the present toolchain admits 29,894 before any filtering. Until
that divergence is understood, regenerating the blob would silently drop ~5,400 words
for unrelated reasons. This tool therefore edits the existing blob in place and
changes exactly one thing.

Every word is preserved. Only the `posBits` array is modified, so the stripped words
remain available for rhymes and syllable lookups; they simply become ineligible for
the POS-typed content slots the assembler and the spark provider fill.

SFLX v1 layout (see build_lexicon.py):
  header 32B, then stringOffsets u32[n+1], syllables u8[n], stressBits u16[n],
  openBits u16[n], posBits u16[n], zipf u8[n], valence i8[n], cluster u8[n],
  rhymeKey u32[n], then the strings blob.

Usage: filter_lexicon_pos.py <lexicon.bin> [output.bin]   (in place if no output)
"""

import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from build_lexicon import has_headword_stem, load_headwords  # noqa: E402


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__.strip().splitlines()[-1])
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else src

    data = bytearray(src.read_bytes())
    magic, version, n, strings_off, strings_len = struct.unpack_from("<4sIIII", data, 0)
    if magic != b"SFLX" or version != 1:
        raise SystemExit(f"{src}: not an SFLX v1 blob")

    offsets = struct.unpack_from(f"<{n + 1}I", data, 32)
    pos_off = 32 + (n + 1) * 4 + n + n * 2 + n * 2
    blob = data[strings_off:strings_off + strings_len]

    headwords = load_headwords()
    stripped = []
    for i in range(n):
        at = pos_off + i * 2
        (pos,) = struct.unpack_from("<H", data, at)
        if not pos:
            continue
        text = blob[offsets[i]:offsets[i + 1]].decode()
        if has_headword_stem(text, headwords):
            continue
        struct.pack_into("<H", data, at, 0)
        stripped.append(text)

    dst.write_bytes(bytes(data))
    print(f"{src.name}: {n:,} words, stripped POS from {len(stripped):,} "
          f"({100 * len(stripped) / n:.1f}%)")
    print(f"wrote {dst} ({dst.stat().st_size:,} bytes)")

    # The words that produced the fragment lines must now be ineligible for content
    # slots, and ordinary inflected vocabulary must be untouched.
    def pos_of(word):
        for i in range(n):
            if blob[offsets[i]:offsets[i + 1]].decode() == word:
                return struct.unpack_from("<H", data, pos_off + i * 2)[0]
        return None

    for w in ["russ", "rica", "liu", "mc", "le", "bahrain", "hindu"]:
        assert pos_of(w) in (0, None), f"{w} still POS-tagged"
    for w in ["guiding", "fulfilling", "lashed", "stripped", "hollow", "ache", "freight"]:
        assert pos_of(w), f"{w} lost its POS tags"
    print("self-checks passed")


if __name__ == "__main__":
    main()
