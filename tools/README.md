# tools

Build-time data pipeline and verification harnesses. Nothing here ships in the app.

Everything except `build_lexicon.py` runs on a bare Python 3 with no dependencies, so it
works in a container with no Swift toolchain — which is where most of the verification in
this project has actually happened.

| Script | What it answers |
|---|---|
| `build_lexicon.py` | (below) — regenerates `lexicon.bin` |
| `verify_syllables.py` | Is `SyllableCounter`'s heuristic getting better or worse? |
| `verify_sparks.py` | Do the spark panels actually vary across phrases? |
| `offline_engine_replica.py` | What would the assembler produce for this spec? |
| `check_no_network.sh` | Can anything in the app reach a network? |

`check_no_network.sh` also runs in CI on every pull request. The rest are run by hand.

```sh
python3 tools/verify_syllables.py --compare          # every rule variant, side by side
python3 tools/verify_syllables.py --words handled belle aisle
./tools/check_no_network.sh
```

The measurement rule for the two `verify_*` scripts: port the Swift heuristic to Python,
run it over the real `lexicon.bin`, and keep the change only if the number improves. Two
plausible-looking syllable rules were dropped that way after scoring worse — see
`docs/HANDOFF.md` §"The lexicon is ground truth".

## build_lexicon.py

Assembles `Packages/LyricEngine/Sources/LyricEngine/Resources/lexicon.bin`
(SFLX v1 packed binary — format documented in the script header) from:

| Source | File | License |
|---|---|---|
| CMUdict 0.7b | `data/cmudict-0.7b` | BSD-2-Clause |
| Moby POS | `data/mobypos.txt` | Public domain |
| VADER lexicon | `data/vader_lexicon.txt` | MIT |
| wordfreq (pip) | `.venv` | MIT (data permissions documented upstream) |

Setup and run:

```sh
cd tools
python3 -m venv .venv && .venv/bin/pip install wordfreq
curl -sL -o data/cmudict-0.7b https://raw.githubusercontent.com/Alexir/CMUdict/master/cmudict-0.7b
curl -sL -o data/mobypos.txt https://www.gutenberg.org/files/3203/files/mobypos.txt
curl -sL -o data/vader_lexicon.txt https://raw.githubusercontent.com/cjhutto/vaderSentiment/master/vaderSentiment/vader_lexicon.txt
.venv/bin/python3 build_lexicon.py
```

The script asserts its own acceptance checks (word counts, stress/openness
goldens, rhyme keys) and fails loudly if a source file's format drifts.
The generated `lexicon.bin` IS committed (the app build needs it); the raw
downloads and venv are not.
