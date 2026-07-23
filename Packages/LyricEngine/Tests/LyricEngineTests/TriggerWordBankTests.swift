import Testing
import Domain
@testable import LyricEngine

struct TriggerWordBankTests {

    @Test func everyEmotionMapsToANonEmptyState() {
        for emotion in Emotion.allCases {
            #expect(!TriggerWordBank.words(for: emotion).isEmpty,
                    "\(emotion) has no trigger words")
        }
    }

    @Test func triggerWordsAreLowercaseSingleTokens() {
        for emotion in Emotion.allCases {
            for word in TriggerWordBank.words(for: emotion) {
                #expect(word == word.lowercased(), "'\(word)' is not lowercase")
                #expect(!word.contains(" "), "'\(word)' is multi-word — cannot match a lexicon entry")
            }
        }
    }

    @Test func triggerWordsResolveInTheLexicon() {
        // The boost only fires on words the lexicon actually serves; a trigger word
        // missing from the lexicon is dead weight and probably a typo.
        var missing: [String] = []
        for emotion in Emotion.allCases {
            for word in TriggerWordBank.words(for: emotion) where Fixtures.store.lookup(word) == nil {
                missing.append(word)
            }
        }
        #expect(missing.isEmpty, "trigger words absent from lexicon: \(missing)")
    }
}
