import Foundation

/// The deterministic ranking engine (docs/ARCHITECTURE.md §9). Computes every objective
/// axis on-device — the model is never the judge of syllables or stress. Candidates whose
/// `syllableFit` falls below `dropThreshold` are excluded entirely.
public struct CandidateRanker: CandidateRanking, Sendable {
    public static let dropThreshold = 0.3
    static let syllableErrorPenalty = 0.35

    public init() {}

    public func rank(_ candidates: [LyricCandidate], spec: PhraseSpec, memory: SessionMemory) -> [RankedCandidate] {
        candidates
            .map { score($0, spec: spec, memory: memory) }
            .filter { $0.score.syllableFit >= Self.dropThreshold }
            .sorted { $0.score.total > $1.score.total }
    }

    func score(_ candidate: LyricCandidate, spec: PhraseSpec, memory: SessionMemory) -> RankedCandidate {
        let analysis = SyllableCounter.analyze(line: candidate.text)

        let syllableFit = Self.syllableFitScore(measuredCount: analysis.syllableCount, budget: spec.budget)
        let stressFit = Self.stressFitScore(measuredStress: analysis.stressPattern, target: spec.budget.stressMap)
        let singability = SingabilityScorer.score(text: candidate.text, spec: spec)
        let continuity = ContinuityScorer.score(candidateText: candidate.text, memory: memory)

        let emotionalFit: Double
        let memorability: Double
        if let modelScores = candidate.modelScores {
            emotionalFit = modelScores.emotionalFit
            memorability = modelScores.memorability
        } else {
            emotionalFit = Self.lexiconEmotionOverlap(text: candidate.text, spec: spec)
            memorability = 0.5
        }

        let lyricScore = LyricScore(
            syllableFit: syllableFit,
            stressFit: stressFit,
            singability: singability,
            emotionalFit: emotionalFit,
            continuity: continuity,
            memorability: memorability
        )
        return RankedCandidate(candidate: candidate, score: lyricScore)
    }

    /// 1.0 within tolerance, decaying `syllableErrorPenalty` per syllable beyond it.
    static func syllableFitScore(measuredCount: Int, budget: SyllableBudget) -> Double {
        if budget.contains(measuredCount) { return 1.0 }
        let distance = measuredCount < budget.range.lowerBound
            ? budget.range.lowerBound - measuredCount
            : measuredCount - budget.range.upperBound
        return max(0, 1.0 - Double(distance) * syllableErrorPenalty)
    }

    /// Fraction of Strong slots whose measured stress agrees with the target stress map.
    /// "toDAY i FOUND" against a "SwS" target scores low — this is the classic misstress
    /// that must sink a candidate (docs/ARCHITECTURE.md §9).
    static func stressFitScore(measuredStress: [Stress], target: StressMap) -> Double {
        guard !target.pattern.isEmpty else { return measuredStress.isEmpty ? 1.0 : 0.5 }
        let strongIndices = target.pattern.indices.filter { target.pattern[$0] == .strong }
        guard !strongIndices.isEmpty else { return 1.0 }

        var agree = 0
        for i in strongIndices {
            guard i < measuredStress.count else { continue }
            if measuredStress[i] == .strong { agree += 1 }
        }
        return Double(agree) / Double(strongIndices.count)
    }

    /// Offline-provider fallback when there's no LLM self-report: crude lexical overlap
    /// between the candidate's words and the emotion's theme-adjacent vocabulary.
    static func lexiconEmotionOverlap(text: String, spec: PhraseSpec) -> Double {
        guard let top = spec.topEmotions.first else { return 0.5 }
        let words = Set(SyllableCounter.words(in: text))
        let lexicon = EmotionLexicon.words(for: top.emotion)
        let hits = words.intersection(lexicon).count
        return hits > 0 ? min(1, 0.5 + Double(hits) * 0.15) : 0.4
    }
}

/// A small per-emotion word bank, used only as the offline-provider emotional-fit proxy
/// (docs/ARCHITECTURE.md §9: "offline candidates get rule-based emotionalFit").
enum EmotionLexicon {
    static func words(for emotion: Emotion) -> Set<String> {
        switch emotion {
        case .longing: ["still", "wait", "waiting", "reach", "reaching", "far", "distance", "call", "calling", "gone"]
        case .joy: ["bright", "light", "shine", "shining", "dance", "dancing", "sun", "sing", "singing", "free"]
        case .nostalgia: ["remember", "memories", "again", "back", "used", "old", "before", "then", "were"]
        case .reflection: ["quiet", "silence", "silent", "still", "think", "wonder", "alone", "mind"]
        case .tension: ["storm", "burn", "burning", "break", "breaking", "tight", "close", "fall", "falling"]
        case .release: ["let", "go", "free", "breathe", "open", "fall", "falling", "down", "gone"]
        case .hope: ["light", "dawn", "rise", "rising", "again", "new", "morning", "open"]
        case .melancholy: ["cold", "gray", "rain", "alone", "gone", "fade", "fading", "gray", "shadow", "shadows"]
        }
    }
}
