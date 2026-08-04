import Testing
import Foundation
@testable import Domain

/// `record` is what makes keeping-every-line usable. A phrase's line goes onto the sheet
/// as soon as it arrives, and every retry for that phrase — regenerate, more-like-this,
/// a different emotion, a syllable nudge — has to *replace* it. Appending blindly would
/// turn a writer who fiddled with one line into six copies of it.
@Suite struct SessionMemoryRecordTests {

    private func line(_ text: String, phraseID: UUID, emotion: Emotion = .hope) -> LyricLine {
        LyricLine(phraseID: phraseID, text: text,
                  stressMap: StressMap(pattern: [.strong]), emotion: emotion, acceptedAt: Date())
    }

    @Test func aNewPhraseAppendsAndDisplacesNothing() {
        var memory = SessionMemory()
        let replaced = memory.record(line("the first line", phraseID: UUID()))
        #expect(replaced == nil)
        #expect(memory.acceptedLines.map(\.text) == ["the first line"])
    }

    @Test func retryingTheSamePhraseReplacesItsLineInPlace() {
        var memory = SessionMemory()
        let phrase = UUID()
        memory.record(line("first attempt", phraseID: phrase))
        let replaced = memory.record(line("second attempt", phraseID: phrase))

        #expect(replaced?.text == "first attempt")
        #expect(memory.acceptedLines.map(\.text) == ["second attempt"],
                "a retry added a line instead of replacing one")
    }

    @Test func repeatedRetriesNeverGrowTheSheet() {
        var memory = SessionMemory()
        let phrase = UUID()
        for attempt in 1...6 {
            memory.record(line("attempt \(attempt)", phraseID: phrase))
        }
        #expect(memory.acceptedLines.count == 1)
        #expect(memory.acceptedLines.first?.text == "attempt 6")
    }

    @Test func replacementKeepsThePhrasePositionRatherThanMovingToTheEnd() {
        // The sheet is the song in the order it was played. Rewriting the first line
        // must not shuffle it below the second.
        var memory = SessionMemory()
        let first = UUID()
        let second = UUID()
        memory.record(line("verse one", phraseID: first))
        memory.record(line("verse two", phraseID: second))

        memory.record(line("verse one, again", phraseID: first))

        #expect(memory.acceptedLines.map(\.text) == ["verse one, again", "verse two"])
    }

    @Test func differentPhrasesEachKeepTheirOwnLine() {
        var memory = SessionMemory()
        for i in 1...4 {
            memory.record(line("line \(i)", phraseID: UUID()))
        }
        #expect(memory.acceptedLines.count == 4)
    }
}
