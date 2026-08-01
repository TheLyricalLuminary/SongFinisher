import Testing
import Foundation
import Domain
@testable import SongFinisher

/// Flow mode records the song as it is played: a line lands on the sheet the moment it
/// arrives, not when the next phrase pushes it off screen. Under the old ordering a
/// writer who played one phrase and then stopped to look had an empty sheet — the
/// feature existed and was invisible.
///
/// The replace-by-phrase rule that makes automatic keeping safe lives in
/// `SessionMemory.record`, and is tested directly in `SessionMemoryRecordTests`.
///
/// Serialized because flow mode's preference lives in `UserDefaults.standard`.
@Suite(.serialized) @MainActor struct SongSheetKeepingTests {

    private static let key = "session.flowMode"

    private func line(_ text: String) -> LyricLine {
        LyricLine(phraseID: UUID(), text: text,
                  stressMap: StressMap(pattern: [.strong]), emotion: .hope, acceptedAt: Date())
    }

    @Test func aSessionResumesOntoTheExistingSheet() {
        // Reopening a song continues its sheet rather than starting a blank one — the
        // point of recording as you play is that the song is still there next time.
        var memory = SessionMemory()
        memory.acceptedLines = [line("verse one"), line("verse two")]
        let vm = SessionViewModel(services: .fakes(), initialMemory: memory)

        #expect(vm.sessionMemory.acceptedLines.map(\.text) == ["verse one", "verse two"])
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    @Test func undoTakesBackTheNewestLineOnly() {
        var memory = SessionMemory()
        memory.acceptedLines = [line("the first line"), line("the second line")]
        let vm = SessionViewModel(services: .fakes(), initialMemory: memory)

        vm.undoLastAccepted()

        #expect(vm.sessionMemory.acceptedLines.map(\.text) == ["the first line"])
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    @Test func nothingIsKeptBeforeAnythingIsPlayed() {
        // The sheet starts empty even with flow mode on: keeping is driven by lines
        // arriving, not by the toggle.
        UserDefaults.standard.removeObject(forKey: Self.key)
        let vm = SessionViewModel(services: .fakes())
        vm.isFlowMode = true

        #expect(vm.sessionMemory.acceptedLines.isEmpty)
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}
