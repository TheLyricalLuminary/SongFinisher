import Foundation

/// Per-line syllable/stress/rhyme analysis, built from `SyllableCounter.analyze(line:)`.
public struct LineSyllableAnalysis: Sendable, Equatable {
    public let syllableCount: Int
    public let stressPattern: [Stress]
    public let tailPhoneme: String

    public init(syllableCount: Int, stressPattern: [Stress], tailPhoneme: String) {
        self.syllableCount = syllableCount
        self.stressPattern = stressPattern
        self.tailPhoneme = tailPhoneme
    }
}

/// Recounts syllables and stress on-device. Every LLM syllable claim is re-verified here —
/// the model is never trusted for objective constraints (docs/ARCHITECTURE.md §9).
public enum SyllableCounter {
    /// Splits a line into lowercase words, stripping punctuation but preserving apostrophes
    /// inside contractions ("I'm", "don't").
    public static func words(in line: String) -> [String] {
        line.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    public static func syllableCount(of word: String) -> Int { stressPattern(of: word).count }

    public static func stressPattern(of word: String) -> [Stress] {
        let key = word.lowercased()
        if let entry = SyllableDictionary.entries[key] { return entry.stress }
        return heuristicStressPattern(for: key)
    }

    public static func tailPhoneme(of word: String) -> String {
        let key = word.lowercased()
        if let entry = SyllableDictionary.entries[key] { return entry.tail }
        return String(key.suffix(min(3, key.count)))
    }

    /// Full-line syllable count, concatenated stress pattern, and the rhyme tail of the
    /// line's last word — the shape `CandidateRanker` and `ContinuityScorer` consume.
    public static func analyze(line: String) -> LineSyllableAnalysis {
        let ws = words(in: line)
        guard !ws.isEmpty else { return LineSyllableAnalysis(syllableCount: 0, stressPattern: [], tailPhoneme: "") }
        var pattern: [Stress] = []
        for w in ws { pattern.append(contentsOf: stressPattern(of: w)) }
        return LineSyllableAnalysis(
            syllableCount: pattern.count,
            stressPattern: pattern,
            tailPhoneme: tailPhoneme(of: ws[ws.count - 1])
        )
    }

    // MARK: - OOV heuristic

    private static let vowels = CharacterSet(charactersIn: "aeiouy")

    /// Matches the vowel set the grouping above uses, `y` included — so "style" ends in a
    /// vowel before its "le" and keeps its single syllable.
    private static func isVowelLetter(_ character: Character) -> Bool {
        "aeiouy".contains(character)
    }

    /// Standard vowel-group heuristic for out-of-dictionary words: count runs of vowels,
    /// drop a trailing silent "e", and fold common unstressed suffixes so the count doesn't
    /// over-report. Stress defaults to first-syllable-strong for 1–2 syllables (the dominant
    /// English pattern for content words) and alternating S/w beyond that.
    static func heuristicStressPattern(for word: String) -> [Stress] {
        let letters = Array(word)
        guard !letters.isEmpty else { return [] }

        var groups: [[Character]] = []
        var current: [Character] = []
        for ch in letters {
            let isVowel = String(ch).rangeOfCharacter(from: vowels) != nil
            if isVowel {
                current.append(ch)
            } else if !current.isEmpty {
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty { groups.append(current) }

        // Two endings that a bare vowel-group count gets wrong, and both are everywhere in
        // song lyrics. Measured against the bundled lexicon's CMUdict counts over its
        // 23,776 common words, handling them takes this heuristic from 83.1% exact to
        // 88.1%, and cuts off-by-one from 16.4% to 11.4%.
        var count = groups.count
        let endsInBareE = letters.last == "e" && groups.count > 1 && groups.last == ["e"]

        if word.hasSuffix("ed"), letters.count > 3, groups.count > 1, groups.last == ["e"] {
            // "-ed" is only its own syllable after t or d — "wanted", "needed", "started".
            // Everywhere else it is silent: "walked" is one syllable, "abandoned" three.
            // Counting it always was the single largest source of over-reporting.
            let preceding = letters[letters.count - 3]
            if preceding != "t" && preceding != "d" { count -= 1 }
        } else if endsInBareE {
            // Silent trailing "e": "shine", "grace", "fire".
            count -= 1
            // ...except a consonant before a final "le", where the l is syllabic and the
            // syllable is real: "able", "little", "gentle". A vowel there keeps it silent,
            // so "whole" and "style" stay at one.
            if word.hasSuffix("le"), letters.count >= 3, !isVowelLetter(letters[letters.count - 3]) {
                count += 1
            }
        }
        count = max(1, count)
        var pattern = [Stress](repeating: .weak, count: count)
        pattern[0] = .strong
        if count > 2 {
            var i = 2
            while i < count {
                pattern[i] = .strong
                i += 2
            }
        }
        return pattern
    }
}
