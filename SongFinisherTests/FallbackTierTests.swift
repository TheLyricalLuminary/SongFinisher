import Testing
import Foundation
import Domain
@testable import SongFinisher

/// A stand-in for the Foundation Models provider so the premium tier can be exercised
/// on any host, including CI machines with no Apple Intelligence.
private struct FakeAIProvider: LyricProviding {
    var kind: ProviderKind { .appleIntelligence }
    func candidates(for spec: PhraseSpec, memory: SessionMemory) async throws(LyricProviderError) -> [LyricCandidate] {
        [LyricCandidate(
            phraseID: spec.phraseID,
            text: "a line the model wrote",
            syllableCount: spec.budget.target,
            stressAlignment: spec.budget.stressMap.pattern,
            provider: .appleIntelligence
        )]
    }
}

/// Records whether the session asked it to warm up.
private final class PrewarmSpy: LyricProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _prewarmed = false
    var prewarmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return _prewarmed
    }

    var kind: ProviderKind { .appleIntelligence }

    func prewarm() async {
        lock.lock()
        _prewarmed = true
        lock.unlock()
    }

    func candidates(for spec: PhraseSpec, memory: SessionMemory) async throws(LyricProviderError) -> [LyricCandidate] { [] }
}

/// The offline assembler fits meter but has no model of meaning, so the session screen
/// leads with word sparks — real words, chosen for the phrase's emotion, meaningful by
/// construction — and demotes the assembled draft to a starting point. On the AI tier the
/// generated line genuinely is the answer and leads. `lastProviderKind` is the signal the
/// layout reads, so these pin when it says "offline".
@MainActor struct FallbackTierTests {

    @Test func offlineTierIsKnownBeforeTheFirstPhrase() {
        // Not `nil`-until-first-line: the screen has to be laid out correctly for the
        // very first phrase of a session, not reorder under the writer once a draft
        // lands. `AppServices` already resolved the engine at composition time.
        let viewModel = SessionViewModel(services: .fakes(lyrics: FakeLyricProvider()))
        #expect(viewModel.lastProviderKind == .offline)
    }

    @Test func premiumTierLeadsWithTheGeneratedLine() {
        let viewModel = SessionViewModel(services: .fakes(lyrics: FakeAIProvider()))
        #expect(viewModel.lastProviderKind == .appleIntelligence)
    }

    @Test func startingASessionWarmsTheGenerationModel() async throws {
        // Foundation Models lazy-loads on first request. Without a warm-up kicked off
        // when listening starts, that load lands on the writer's first phrase and shows
        // as seconds of suggestion spinner — the first impression anyone gets of the app,
        // including whoever is being demoed to.
        let spy = PrewarmSpy()
        let viewModel = SessionViewModel(services: .fakes(lyrics: spy))

        viewModel.start()
        defer { viewModel.stop() }

        // `start` fires the warm-up as a detached task rather than blocking capture,
        // so give the main actor a turn before asserting.
        try await Task.sleep(for: .milliseconds(50))
        #expect(spy.prewarmed, "starting a session did not warm the generation model")
    }
}
