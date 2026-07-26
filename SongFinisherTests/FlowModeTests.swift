import Testing
import Foundation
import Domain
@testable import SongFinisher

private func line(_ text: String, _ emotion: Emotion) -> LyricLine {
    LyricLine(
        phraseID: UUID(),
        text: text,
        stressMap: StressMap(pattern: [.strong, .weak]),
        emotion: emotion,
        acceptedAt: Date()
    )
}

/// Flow mode is the hands-free contract: a writer mid-take never touches the screen, so
/// "played the next phrase" has to mean "kept the last line". These tests pin that
/// bookkeeping — and pin that the mode stays off unless asked for, since silently keeping
/// lines would be surprising for someone who wants to choose each one.
///
/// Serialized because the preference lives in `UserDefaults.standard`: parallel cases
/// would race on the same key.
@Suite(.serialized) @MainActor struct FlowModeTests {

    private static let key = "session.flowMode"

    private func freshViewModel(memory: SessionMemory = SessionMemory()) -> SessionViewModel {
        UserDefaults.standard.removeObject(forKey: Self.key)
        return SessionViewModel(services: .fakes(), initialMemory: memory)
    }

    @Test func flowModeIsOffByDefault() {
        #expect(freshViewModel().isFlowMode == false)
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    @Test func flowModePreferenceSurvivesANewSession() {
        let first = freshViewModel()
        first.isFlowMode = true

        // A second view model (new screen, same app) inherits the choice — a writer who
        // works hands-free shouldn't have to re-enable it every session.
        #expect(SessionViewModel(services: .fakes()).isFlowMode)
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    @Test func undoWithNothingAcceptedIsHarmless() {
        let viewModel = freshViewModel()
        viewModel.undoLastAccepted()
        #expect(viewModel.sessionMemory.acceptedLines.isEmpty)
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    @Test func undoRemovesOnlyTheMostRecentLine() {
        var memory = SessionMemory()
        memory.acceptedLines = [line("the first line", .hope), line("the second line", .joy)]
        memory.dominantEmotion = .joy
        let viewModel = freshViewModel(memory: memory)

        viewModel.undoLastAccepted()

        #expect(viewModel.sessionMemory.acceptedLines.map(\.text) == ["the first line"])
        // Dominant emotion falls back to the surviving line rather than staying on the
        // removed one — otherwise the next generation chases a mood the writer took back.
        #expect(viewModel.sessionMemory.dominantEmotion == .hope)
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    @Test func undoingEveryLineClearsTheDominantEmotion() {
        var memory = SessionMemory()
        memory.acceptedLines = [line("the only line", .melancholy)]
        memory.dominantEmotion = .melancholy
        let viewModel = freshViewModel(memory: memory)

        viewModel.undoLastAccepted()

        #expect(viewModel.sessionMemory.acceptedLines.isEmpty)
        #expect(viewModel.sessionMemory.dominantEmotion == nil)
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}
