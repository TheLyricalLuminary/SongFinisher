/// What can actually go wrong when generating on-device. There are deliberately no
/// `network` / `unauthorized` / `rateLimited` cases: every provider runs locally, so
/// those failures have no way to occur, and carrying them at the seam would imply a
/// remote path this app does not have.
public enum LyricProviderError: Error, Sendable, Equatable {
    /// The model returned something unusable — empty, malformed, or refused.
    case invalidResponse(String)
    case cancelled
}

/// THE provider-agnostic seam (docs/ARCHITECTURE.md §9). Concrete implementations
/// (Foundation Models, offline) live in LyricEngine; the ViewModel only ever sees
/// this protocol.
public protocol LyricProviding: Sendable {
    var kind: ProviderKind { get }
    /// Load whatever the provider needs before its first request — model weights,
    /// caches, sessions. Called when a listening session starts, while the writer is
    /// still settling in front of the mic, so the first phrase meets a warm engine
    /// instead of a cold start wearing a suggestion spinner.
    func prewarm() async
    func candidates(for spec: PhraseSpec, memory: SessionMemory) async throws(LyricProviderError) -> [LyricCandidate]
}

public extension LyricProviding {
    /// Most providers — the lexicon assembler, test fakes — have nothing to warm.
    func prewarm() async {}
}
