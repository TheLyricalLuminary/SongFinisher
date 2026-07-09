import Foundation

/// Phonetic singability: open vowels on long/strong notes score well, consonant clusters
/// on fast notes are penalized (docs/ARCHITECTURE.md §9).
public enum SingabilityScorer {
    private static let openVowelSounds: Set<Character> = ["a", "o"]
    private static let consonants = CharacterSet.letters.subtracting(CharacterSet(charactersIn: "aeiouAEIOUyY"))

    public static func score(text: String, spec: PhraseSpec) -> Double {
        let words = SyllableCounter.words(in: text)
        guard !words.isEmpty else { return 0 }

        let longSlotIndices = Set(spec.longNoteSlots)
        var slotIndex = 0
        var total = 0.0
        var slotCount = 0

        for word in words {
            let syllableCount = SyllableCounter.syllableCount(of: word)
            let hasOpenVowel = word.lowercased().contains { openVowelSounds.contains($0) }
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
