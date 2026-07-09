import Foundation

/// Rhyme-tail match and motif echo score positively; near-verbatim overlap with an accepted
/// line scores negatively (it's a copy, not a continuation) — docs/ARCHITECTURE.md §9.
public enum ContinuityScorer {
    public static func score(candidateText: String, memory: SessionMemory) -> Double {
        var score = 0.5

        let analysis = SyllableCounter.analyze(line: candidateText)
        if !memory.rhymeTails.isEmpty {
            if memory.rhymeTails.contains(where: { $0 == analysis.tailPhoneme }) {
                score += 0.25
            }
        }

        let candidateWords = Set(SyllableCounter.words(in: candidateText))
        for theme in memory.themes where candidateWords.contains(theme.lowercased()) {
            score += 0.1
        }
        for motif in memory.motifs where candidateText.lowercased().contains(motif.lowercased()) {
            score += 0.1
        }

        for line in memory.acceptedLines {
            let overlap = wordOverlapRatio(candidateText, line.text)
            if overlap >= 0.6 { score -= 0.4 }
        }

        return min(1, max(0, score))
    }

    private static func wordOverlapRatio(_ a: String, _ b: String) -> Double {
        let wordsA = Set(SyllableCounter.words(in: a))
        let wordsB = Set(SyllableCounter.words(in: b))
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return 0 }
        let intersection = wordsA.intersection(wordsB).count
        return Double(intersection) / Double(min(wordsA.count, wordsB.count))
    }
}
