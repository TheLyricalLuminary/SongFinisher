import Testing
import Foundation
@testable import Domain

@Suite struct ContinuityScorerTests {

    @Test func rhymeTailMatchBoostsScore() {
        var memory = SessionMemory()
        memory.rhymeTails = [SyllableCounter.tailPhoneme(of: "night")]
        let withRhyme = ContinuityScorer.score(candidateText: "waiting for the light", memory: memory)
        let withoutRhyme = ContinuityScorer.score(candidateText: "waiting in the room", memory: memory)
        #expect(withRhyme > withoutRhyme)
    }

    @Test func themeWordOverlapBoostsScore() {
        var memory = SessionMemory()
        memory.themes = ["highway", "rain"]
        let onTheme = ContinuityScorer.score(candidateText: "the highway swallows the light", memory: memory)
        let offTheme = ContinuityScorer.score(candidateText: "a quiet room and a chair", memory: memory)
        #expect(onTheme > offTheme)
    }

    @Test func motifEchoBoostsScore() {
        var memory = SessionMemory()
        memory.motifs = ["counting exits"]
        let withMotif = ContinuityScorer.score(candidateText: "still counting exits alone", memory: memory)
        let withoutMotif = ContinuityScorer.score(candidateText: "still driving through the dark", memory: memory)
        #expect(withMotif > withoutMotif)
    }

    @Test func nearVerbatimOverlapWithAcceptedLinePenalizesScore() {
        var memory = SessionMemory()
        memory.acceptedLines = [
            LyricLine(phraseID: UUID(), text: "taillights bleeding down the interstate", stressMap: StressMap(pattern: []), emotion: .longing, acceptedAt: Date())
        ]
        let nearCopy = ContinuityScorer.score(candidateText: "taillights bleeding down the interstate again", memory: memory)
        let fresh = ContinuityScorer.score(candidateText: "a stranger's porch light in the fog", memory: memory)
        #expect(nearCopy < fresh)
    }

    @Test func emptyMemoryProducesNeutralBaselineScore() {
        let score = ContinuityScorer.score(candidateText: "anything at all", memory: SessionMemory())
        #expect(score == 0.5)
    }

    @Test func scoreIsAlwaysClampedToUnitRange() {
        var memory = SessionMemory()
        memory.themes = ["light", "night", "sky", "star", "moon", "sun", "rain", "wind"]
        memory.motifs = ["light night sky star moon sun rain wind"]
        memory.rhymeTails = [SyllableCounter.tailPhoneme(of: "wind")]
        let score = ContinuityScorer.score(candidateText: "light night sky star moon sun rain wind", memory: memory)
        #expect(score <= 1.0)
        #expect(score >= 0.0)
    }
}
