# Acknowledgements

Song Finisher's offline lyric engine is built on the following data sources,
assembled at build time by `tools/build_lexicon.py` into `lexicon.bin`.
Re-verify each license text in the downloaded artifact before shipping.

## CMU Pronouncing Dictionary (cmudict-0.7b)
Copyright (C) 1993–2015 Carnegie Mellon University. All rights reserved.
Used under the BSD-2-Clause license for pronunciation, syllable, and stress data.
http://www.speech.cs.cmu.edu/cgi-bin/cmudict

## Moby Part-of-Speech List
From the Moby Project by Grady Ward, released into the public domain.
Used for part-of-speech tags. https://www.gutenberg.org/ebooks/3203

## wordfreq (word frequencies, incl. SUBTLEX-US)
Word frequencies from the wordfreq project (Robyn Speer), MIT-licensed code with
documented redistribution permission for its data sources. Frequencies derive in
part from SUBTLEX-US: Brysbaert, M. & New, B. (2009), "Moving beyond Kučera and
Francis: A critical evaluation of current word frequency norms and the
introduction of a new and improved word frequency measure for American English,"
Behavior Research Methods 41(4), 977–990. https://github.com/rspeer/wordfreq

## VADER Sentiment Lexicon
Hutto, C.J. & Gilbert, E.E. (2014), "VADER: A Parsimonious Rule-based Model for
Sentiment Analysis of Social Media Text," ICWSM-14. MIT license.
https://github.com/cjhutto/vaderSentiment

## Deliberately NOT bundled (license restrictions)
- NRC Word-Emotion Association Lexicon (EmoLex) — requires a paid commercial license.
- Warriner/Kuperman/Brysbaert (2013) VAD norms — © Psychonomic Society, no commercial grant.
- espeak-ng — GPL; incompatible with a closed-source bundle.
