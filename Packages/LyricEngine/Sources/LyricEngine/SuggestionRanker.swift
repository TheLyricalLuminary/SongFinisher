import Foundation

/// Weighted combine + maximal-marginal-relevance diversity re-ranking (Task 2 / spec
/// section 3). Selects the top `count` lines from a pool such that each pick balances
/// its own quality against dissimilarity from already-picked lines.
enum SuggestionRanker {
    static let prosodyWeight = 0.45
    static let fluencyWeight = 0.25
    static let emotionWeight = 0.20
    static let diversityPenaltyWeight = 0.10

    static func quality(_ line: AssembledLine) -> Double {
        prosodyWeight * line.prosodyScore + fluencyWeight * line.fluencyScore + emotionWeight * line.emotionScore
    }

    /// Greedy MMR selection. `pool` need not be pre-sorted.
    static func select(from pool: [AssembledLine], count: Int) -> [AssembledLine] {
        guard !pool.isEmpty else { return [] }
        var remaining = pool
        var picked: [AssembledLine] = []

        while picked.count < count, !remaining.isEmpty {
            var bestIndex = 0
            var bestScore = -Double.infinity
            for (i, candidate) in remaining.enumerated() {
                let overlap = picked.map { overlapRatio(candidate, $0) }.max() ?? 0
                let score = quality(candidate) - diversityPenaltyWeight * overlap
                if score > bestScore {
                    bestScore = score
                    bestIndex = i
                }
            }
            picked.append(remaining.remove(at: bestIndex))
        }
        return picked
    }

    /// Jaccard overlap of content-word sets — the diversity/redundancy signal.
    private static func overlapRatio(_ a: AssembledLine, _ b: AssembledLine) -> Double {
        guard !a.contentWords.isEmpty, !b.contentWords.isEmpty else { return 0 }
        let intersection = a.contentWords.intersection(b.contentWords).count
        let union = a.contentWords.union(b.contentWords).count
        return union > 0 ? Double(intersection) / Double(union) : 0
    }
}
