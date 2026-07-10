import Testing
import Foundation
@testable import Domain

@Suite struct SessionMemoryUpdaterTests {

    private func line(_ text: String, emotion: Emotion = .longing) -> LyricLine {
        LyricLine(phraseID: UUID(), text: text, stressMap: StressMap(pattern: []), emotion: emotion, acceptedAt: Date())
    }

    @Test func acceptingAppendsTheLine() {
        let updated = SessionMemoryUpdater.accepting(line("I still hear your name"), into: SessionMemory())
        #expect(updated.acceptedLines.count == 1)
        #expect(updated.acceptedLines.first?.text == "I still hear your name")
    }

    @Test func acceptingRecordsTheRhymeTail() {
        let updated = SessionMemoryUpdater.accepting(line("waiting for the light"), into: SessionMemory())
        #expect(updated.rhymeTails == [SyllableCounter.tailPhoneme(of: "light")])
    }

    @Test func dominantEmotionIsTheModeOfAcceptedLines() {
        var memory = SessionMemory()
        memory = SessionMemoryUpdater.accepting(line("first line", emotion: .joy), into: memory)
        memory = SessionMemoryUpdater.accepting(line("second line", emotion: .melancholy), into: memory)
        memory = SessionMemoryUpdater.accepting(line("third line", emotion: .melancholy), into: memory)
        #expect(memory.dominantEmotion == .melancholy)
    }

    @Test func repeatedWordAcrossAcceptedLinesBecomesAMotif() {
        var memory = SessionMemory()
        memory = SessionMemoryUpdater.accepting(line("the highway swallows the light"), into: memory)
        memory = SessionMemoryUpdater.accepting(line("another highway, another night"), into: memory)
        #expect(memory.motifs.contains("highway"))
    }

    @Test func nonRepeatedWordsAreNotMotifs() {
        var memory = SessionMemory()
        memory = SessionMemoryUpdater.accepting(line("a quiet room"), into: memory)
        #expect(memory.motifs.isEmpty)
    }

    @Test func hookLineIsSetWhenAMotifEmerges() {
        var memory = SessionMemory()
        memory = SessionMemoryUpdater.accepting(line("counting exits on the interstate"), into: memory)
        memory = SessionMemoryUpdater.accepting(line("still counting every mile"), into: memory)
        #expect(memory.hookLine != nil)
    }

    @Test func rejectingAppendsARejectedLineWithReason() {
        let updated = SessionMemoryUpdater.rejecting("a bad line", reason: .regenerated, into: SessionMemory())
        #expect(updated.rejected.count == 1)
        #expect(updated.rejected.first?.reason == .regenerated)
        #expect(updated.rejected.first?.text == "a bad line")
    }

    @Test func rejectingPreservesExistingAcceptedLines() {
        var memory = SessionMemory()
        memory = SessionMemoryUpdater.accepting(line("kept line"), into: memory)
        memory = SessionMemoryUpdater.rejecting("dropped line", reason: .explicitReject, into: memory)
        #expect(memory.acceptedLines.count == 1)
        #expect(memory.rejected.count == 1)
    }
}
