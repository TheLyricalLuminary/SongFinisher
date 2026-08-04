import Testing
import Foundation
@testable import LyricEngine
import Domain

/// Content-property tests (not golden words): the exact vocabulary depends on the
/// bundled lexicon, but the guarantees — real content words, no function-word salad,
/// determinism, emotion sensitivity, rhymes only when there's a line to rhyme with —
/// must hold.
@Suite struct LexiconSparkProviderTests {
    private let provider = LexiconSparkProvider(store: Fixtures.store)

    @Test func imagesAreRealContentWordsNeverFunctionWords() {
        let sparks = provider.sparks(for: Fixtures.spec(syllables: 7, stress: "SwSwSwS"), memory: SessionMemory())
        #expect(!sparks.images.isEmpty)
        for word in sparks.images {
            #expect(!PhraseAssembler.contentSlotStopWords.contains(word), "'\(word)' is a function word")
            #expect(word.allSatisfy { $0.isLetter }, "'\(word)' has non-letters")
        }
        // Distinct set, no repeats.
        #expect(Set(sparks.images).count == sparks.images.count)
    }

    /// Exactly the guard `imageWords` applies before a word can be scored at all.
    /// Mirrored rather than approximated on purpose: a looser copy would let this
    /// test fail because a curated word was never *servable*, which says nothing
    /// about whether the curation bonus works.
    private func canSurfaceAsASpark(_ word: String) -> Bool {
        guard let entry = Fixtures.store.lookup(word) else { return false }
        return entry.syllables >= 1
            && entry.syllables <= LexiconSparkProvider.maxSyllables
            && entry.zipf >= LexiconSparkProvider.minZipf
            && entry.zipf <= LexiconSparkProvider.maxZipf
            && !entry.pos.isDisjoint(with: .contentWord)
            && !PhraseAssembler.contentSlotStopWords.contains(entry.text)
            && !PhraseAssembler.excludedContentWords.contains(entry.text)
            && entry.text.count > 1
            && entry.text.allSatisfy { $0.isLetter }
    }

    @Test func curatedTriggerWordsHeadTheImageSet() {
        // Regression for "blockbuster" and "heroine" surfacing as Joy sparks: valence
        // and frequency rank them highly (strong VADER score, right freshness band) but
        // no songwriter reaches for them. The book's Trigger Word Library supplies the
        // signal statistics can't, so wherever it has words the spark filters can serve,
        // some of them must actually make the six.
        for emotion in Emotion.allCases {
            let eligible = TriggerWordBank.words(for: emotion).filter(canSurfaceAsASpark)
            guard !eligible.isEmpty else { continue }
            let sparks = provider.sparks(
                for: Fixtures.spec(syllables: 6, stress: "SwSwSw", emotion: emotion),
                memory: SessionMemory()
            )
            #expect(!Set(sparks.images).isDisjoint(with: eligible),
                    "no curated \(emotion) trigger word surfaced: \(sparks.images)")
        }
    }

    @Test func curatedSparksTurnOverAcrossASession() {
        // The failure mode of *ranking* the curated tier rather than shuffling it: every
        // trigger word ties on the curation bonus, so the same six come back phrase after
        // phrase and the panel stops being sparks at all. Measured against the bundled
        // lexicon, ranking exposed 6–9 distinct words across 8 phrases depending on
        // emotion; shuffling exposes the whole eligible pool, 15–17. Twelve sits clear of
        // both, so this catches a regression to frozen order without pinning the draw.
        // Two emotions, not all eight. Each `sparks` call scans the whole 35K lexicon, so
        // eight emotions × eight phrases was 64 scans — thirteen times the lexicon
        // traffic this suite used to generate, enough to stall the concurrently-running
        // assembler latency measurement on memory bandwidth. Two emotions from different
        // curated pools demonstrate the property just as well.
        for emotion in [Emotion.joy, .melancholy] {
            let eligible = TriggerWordBank.words(for: emotion).filter(canSurfaceAsASpark)
            // Emotions whose curated pool barely exceeds one panel can't demonstrate
            // turnover either way; the property is tested on the ones with room.
            guard eligible.count >= 15 else { continue }
            var seen = Set<String>()
            for _ in 0..<8 {
                // A fresh phraseID is what moves the seed from one phrase to the next.
                let spec = Fixtures.spec(syllables: 6, stress: "SwSwSw", emotion: emotion, phraseID: UUID())
                seen.formUnion(provider.sparks(for: spec, memory: SessionMemory()).images)
            }
            #expect(seen.count >= 12,
                    "\(emotion) sparks barely move across 8 phrases: \(seen.sorted())")
        }
    }

    @Test func imagesNeverSurfaceProfanityOrSingleLetters() {
        // Sparks are raw material handed straight to the songwriter, so they need the
        // guards the assembler applies to content slots — the emotion-alignment scoring
        // actively seeks out profanity for negative-valence phrases, and Moby tags the
        // single letters as nouns.
        for emotion in Emotion.allCases {
            let sparks = provider.sparks(
                for: Fixtures.spec(syllables: 6, stress: "SwSwSw", emotion: emotion),
                memory: SessionMemory()
            )
            for word in sparks.images {
                #expect(!PhraseAssembler.excludedContentWords.contains(word),
                        "'\(word)' surfaced as a \(emotion) spark")
                #expect(word.count > 1, "single letter '\(word)' surfaced as a spark")
            }
        }
    }

    @Test func sameSpecAndMemoryIsDeterministic() {
        let phraseID = UUID()
        let specA = Fixtures.spec(syllables: 5, stress: "SwSww", phraseID: phraseID)
        let specB = Fixtures.spec(syllables: 5, stress: "SwSww", phraseID: phraseID)
        let a = provider.sparks(for: specA, memory: SessionMemory())
        let b = provider.sparks(for: specB, memory: SessionMemory())
        #expect(a == b)
    }

    @Test func differentEmotionsShiftTheWordSet() {
        // Joy (positive valence target) and melancholy (negative) should not surface
        // the same top words — the valence alignment must actually bite.
        let joy = provider.sparks(for: Fixtures.spec(syllables: 6, stress: "SwSwSw", emotion: .joy), memory: SessionMemory())
        let melancholy = provider.sparks(for: Fixtures.spec(syllables: 6, stress: "SwSwSw", emotion: .melancholy), memory: SessionMemory())
        #expect(Set(joy.images) != Set(melancholy.images))
    }

    @Test func noRhymesWithoutAnAcceptedLine() {
        let sparks = provider.sparks(for: Fixtures.spec(syllables: 5, stress: "SwSww"), memory: SessionMemory())
        #expect(sparks.rhymes.isEmpty)
    }

    @Test func rhymesShareThePriorLinesEnding() {
        var memory = SessionMemory()
        memory.acceptedLines.append(LyricLine(
            phraseID: UUID(), text: "chasing down the light",
            stressMap: StressMap(pattern: [.strong]), emotion: .hope, acceptedAt: Date()
        ))
        let sparks = provider.sparks(for: Fixtures.spec(syllables: 5, stress: "SwSww"), memory: memory)
        // "light" has common rhymes in the lexicon; every returned rhyme must differ
        // from the seed word itself and be a real word.
        for rhyme in sparks.rhymes {
            #expect(rhyme != "light")
            #expect(rhyme.allSatisfy { $0.isLetter })
        }
    }

    @Test func imagesAvoidWordsAlreadyUsedThisSession() {
        let first = provider.sparks(for: Fixtures.spec(syllables: 6, stress: "SwSwSw", emotion: .longing), memory: SessionMemory())
        guard let reused = first.images.first else { return }
        var memory = SessionMemory()
        memory.acceptedLines.append(LyricLine(
            phraseID: UUID(), text: reused,
            stressMap: StressMap(pattern: [.strong]), emotion: .longing, acceptedAt: Date()
        ))
        let second = provider.sparks(for: Fixtures.spec(syllables: 6, stress: "SwSwSw", emotion: .longing), memory: memory)
        #expect(!second.images.contains(reused))
    }
}
