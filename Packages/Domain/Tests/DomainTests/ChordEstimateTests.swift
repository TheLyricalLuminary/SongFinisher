import Testing
@testable import Domain

@Suite struct ChordEstimateTests {

    @Test func rootNormalizesAnyMidiNoteToAPitchClass() {
        // C4 (60) and C2 (36) are both "C" — root is a pitch class, not an octave-specific note.
        #expect(ChordEstimate(root: 60, quality: .major, confidence: 1).root == 0)
        #expect(ChordEstimate(root: 36, quality: .major, confidence: 1).root == 0)
        #expect(ChordEstimate(root: -1, quality: .major, confidence: 1).root == 11)
    }

    @Test func displayNameMatchesConventionalChordSymbols() {
        #expect(ChordEstimate(root: 0, quality: .major, confidence: 1).displayName == "C")
        #expect(ChordEstimate(root: 9, quality: .minor, confidence: 1).displayName == "Am")
        #expect(ChordEstimate(root: 7, quality: .dominant7, confidence: 1).displayName == "G7")
        #expect(ChordEstimate(root: 11, quality: .diminished, confidence: 1).displayName == "Bdim")
        #expect(ChordEstimate(root: 2, quality: .augmented, confidence: 1).displayName == "D+")
    }

    @Test func spokenNameSpellsOutQualityForVoiceOver() {
        // "Am" reads as the word "am" under VoiceOver — spokenName must spell everything out.
        #expect(ChordEstimate(root: 0, quality: .major, confidence: 1).spokenName == "C major")
        #expect(ChordEstimate(root: 9, quality: .minor, confidence: 1).spokenName == "A minor")
        #expect(ChordEstimate(root: 7, quality: .dominant7, confidence: 1).spokenName == "G dominant seventh")
        #expect(ChordEstimate(root: 11, quality: .diminished, confidence: 1).spokenName == "B diminished")
        #expect(ChordEstimate(root: 1, quality: .augmented, confidence: 1).spokenName == "C sharp augmented")
    }

    @Test func isReliableGatedByConfidenceThreshold() {
        #expect(ChordEstimate(root: 0, quality: .major, confidence: 0.9).isReliable)
        #expect(!ChordEstimate(root: 0, quality: .major, confidence: 0.1).isReliable)
    }

    @Test func minorLikeQualitiesAreMinorAndDiminished() {
        #expect(ChordQuality.minor.isMinorLike)
        #expect(ChordQuality.diminished.isMinorLike)
        #expect(!ChordQuality.major.isMinorLike)
        #expect(!ChordQuality.dominant7.isMinorLike)
        #expect(!ChordQuality.augmented.isMinorLike)
    }
}
