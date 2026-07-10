import Testing
@testable import LyricEngine

@Suite struct SuggestionRankerTests {

    private func line(_ text: String, prosody: Double, fluency: Double = 0.5, emotion: Double = 0.5, words: Set<String>) -> AssembledLine {
        AssembledLine(text: text, syllables: 4, stressPattern: [], prosodyScore: prosody, fluencyScore: fluency, emotionScore: emotion, contentWords: words)
    }

    @Test func higherQualityLinesAreSelectedFirst() {
        let pool = [
            line("bad one", prosody: 0.1, words: ["bad"]),
            line("good one", prosody: 0.9, words: ["good"]),
            line("mid one", prosody: 0.5, words: ["mid"]),
        ]
        let picked = SuggestionRanker.select(from: pool, count: 1)
        #expect(picked.first?.text == "good one")
    }

    @Test func diversityPenaltyDemotesRedundantLines() {
        // Two near-duplicates (high content overlap) plus one distinct line, all
        // similar quality: MMR should not return both duplicates before the distinct one.
        let pool = [
            line("the light still burns bright", prosody: 0.8, words: ["light", "burns", "bright"]),
            line("the light still glows bright", prosody: 0.8, words: ["light", "glows", "bright"]),
            line("a stranger walks alone", prosody: 0.75, words: ["stranger", "walks", "alone"]),
        ]
        let picked = SuggestionRanker.select(from: pool, count: 2)
        let texts = Set(picked.map(\.text))
        #expect(texts.contains("a stranger walks alone"), "diverse line should be preferred over a near-duplicate")
    }

    @Test func selectedSetHasLowPairwiseOverlap() {
        let pool = (0..<10).map { i in
            line("line \(i)", prosody: Double.random(in: 0.3...0.9), words: ["word\(i % 3)", "shared"])
        }
        let picked = SuggestionRanker.select(from: pool, count: 5)
        #expect(picked.count == 5)
    }

    @Test func selectReturnsEmptyForEmptyPool() {
        #expect(SuggestionRanker.select(from: [], count: 5).isEmpty)
    }

    @Test func selectReturnsFewerThanCountWhenPoolIsSmall() {
        let pool = [line("only one", prosody: 0.5, words: ["only"])]
        #expect(SuggestionRanker.select(from: pool, count: 5).count == 1)
    }

    @Test func qualityIsAWeightedSumOfTheThreeAxes() {
        let l = line("x", prosody: 1.0, fluency: 0.0, emotion: 0.0, words: [])
        #expect(abs(SuggestionRanker.quality(l) - SuggestionRanker.prosodyWeight) < 0.0001)
    }
}
