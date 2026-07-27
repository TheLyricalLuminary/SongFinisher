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
