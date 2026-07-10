import Testing
import Foundation
@testable import LyricEngine

@Suite(.serialized) struct LexiconStoreTests {

    @Test func coldLoadIsFast() {
        let start = DispatchTime.now()
        _ = try! LexiconStore.bundled()
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        // Generous ceiling: decoding ~35K short strings once at load should be well
        // under a second even on slow CI, uncontended (.serialized avoids sibling-test
        // CPU contention skewing the measurement); this catches a real regression
        // (e.g. accidental O(n^2) parsing), not micro-timing.
        #expect(elapsedMs < 500, "cold load took \(elapsedMs) ms")
    }

    @Test func lookupFindsKnownWords() {
        let store = Fixtures.store
        let entry = store.lookup("beautiful")
        #expect(entry != nil)
        #expect(entry?.syllables == 3)
        #expect(entry?.stressBits == 0b001)
    }

    @Test func lookupIsCaseInsensitive() {
        #expect(Fixtures.store.lookup("Beautiful") == Fixtures.store.lookup("beautiful"))
    }

    @Test func lookupReturnsNilForUnknownWords() {
        #expect(Fixtures.store.lookup("zzyzxqvvv") == nil)
    }

    @Test func subscriptAndLookupAgree() {
        let store = Fixtures.store
        guard let looked = store.lookup("fire") else {
            Issue.record("fire missing from lexicon")
            return
        }
        let indexed = store[looked.index]
        #expect(indexed.text == "fire")
        #expect(indexed.syllables == 1)
    }

    @Test func openVowelClassificationMatchesBuildScript() {
        // "go" (OW, open) vs "big" (IH, closed) — spot-checks the openness bitfield
        // survives the round trip through the packed binary.
        let go = Fixtures.store.lookup("go")
        let big = Fixtures.store.lookup("big")
        #expect(go?.openBits == 0b1)
        #expect(big?.openBits == 0b0)
    }

    @Test func rhymeKeysMatchForRhymingWordsAndDifferForNonRhymes() {
        let light = Fixtures.store.lookup("light")
        let night = Fixtures.store.lookup("night")
        let love = Fixtures.store.lookup("love")
        #expect(light?.rhymeKey == night?.rhymeKey)
        #expect(light?.rhymeKey != love?.rhymeKey)
    }

    @Test func vocabularySizeIsInExpectedRange() {
        // Zipf >= 2.5 admission should land in the tens of thousands, not a stub.
        #expect(Fixtures.store.count > 15_000)
        #expect(Fixtures.store.count < 80_000)
    }
}
