# tools

Build-time data pipeline (not shipped in the app).

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
