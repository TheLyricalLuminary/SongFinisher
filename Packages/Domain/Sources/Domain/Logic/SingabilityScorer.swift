import Foundation

/// Phonetic singability: open vowels on long/strong notes score well, consonant clusters
/// on fast notes are penalized (docs/ARCHITECTURE.md §9).
public enum SingabilityScorer {
    private static let consonants = CharacterSet.letters.subtracting(CharacterSet(charactersIn: "aeiouAEIOUyY"))

    /// Vowel-group spellings whose nucleus is open (jaw-open, and so sustainable on a
    /// long note): the AY / EY / AW / OW / ER families that a bare letter test misses.
    private static let openSequences = [
        "igh", "ay", "ai", "aw", "au", "ow", "ou", "oa", "oe", "ey", "ye", "er", "ir", "ur",
    ]

    /// Whether a word carries an open, singable vowel.
    ///
    /// Domain has no phoneme data — the CMUdict-derived `openBits` live in LyricEngine's
    /// lexicon, which this layer cannot import — so this reads spelling. It used to be
    /// simply "contains an a or an o", which scored **sky, high, time, eye, my, try, fly,
    /// light, night** and **fire** as closed. Those are among the most sustainable words
    /// in English and exactly what a songwriter reaches for on a held note, so the ranker
    /// was penalising the assembler's best choices for long slots.
    ///
    /// Measured against the bundled lexicon's CMUdict ground truth over the 23,776
    /// common real words it holds, the rule below is right 86.0% of the time against the
    /// old rule's 79.8%, roughly halving missed-open words (3,849 → 1,834). It trades a
    /// few more false-open calls for that, which is the right direction here: wrongly
    /// penalising a genuinely singable word costs a good lyric, while wrongly permitting
    /// one only lets a slightly harder syllable through.
    static func hasOpenNucleus(_ word: String) -> Bool {
        let w = word.lowercased()
        if w.contains("a") || w.contains("o") { return true }
        for sequence in openSequences where w.contains(sequence) { return true }

        let letters = Array(w)
        guard letters.count >= 2 else { return false }
        // sky, my, try, fly — a consonant before a final y is the AY diphthong.
        if letters[letters.count - 1] == "y", isConsonant(letters[letters.count - 2]) {
            return true
        }
        // time, fire, wide — vowel + consonant + silent e lengthens the nucleus.
        if letters.count >= 3, letters[letters.count - 1] == "e",
           isConsonant(letters[letters.count - 2]),
           "aiou".contains(letters[letters.count - 3]) {
            return true
        }
        return false
    }

    private static func isConsonant(_ character: Character) -> Bool {
        character.isLetter && !"aeiou".contains(character)
    }

    public static func score(text: String, spec: PhraseSpec) -> Double {
        let words = SyllableCounter.words(in: text)
        guard !words.isEmpty else { return 0 }

        let longSlotIndices = Set(spec.longNoteSlots)
        var slotIndex = 0
        var total = 0.0
        var slotCount = 0

        for word in words {
            let syllableCount = SyllableCounter.syllableCount(of: word)
            let hasOpenVowel = hasOpenNucleus(word)
            let clusterPenalty = consonantClusterPenalty(in: word)

            for _ in 0..<max(1, syllableCount) {
                var slotScore = 0.5
                if longSlotIndices.contains(slotIndex) {
                    slotScore += hasOpenVowel ? 0.4 : -0.2
                }
                slotScore -= clusterPenalty
                total += min(1, max(0, slotScore))
                slotCount += 1
                slotIndex += 1
            }
        }

        return slotCount > 0 ? total / Double(slotCount) : 0
    }

    /// Penalizes runs of 3+ consecutive consonant letters (hard to sing quickly).
    private static func consonantClusterPenalty(in word: String) -> Double {
        var maxRun = 0
        var currentRun = 0
        for ch in word.lowercased() {
            if String(ch).rangeOfCharacter(from: consonants) != nil {
                currentRun += 1
                maxRun = max(maxRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        return maxRun >= 3 ? 0.15 * Double(maxRun - 2) : 0
    }
}
