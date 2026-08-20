public enum LyricProviderError: Error, Sendable, Equatable {
    case invalidResponse(String)
    case cancelled
}

/// THE provider-agnostic seam (docs/ARCHITECTURE.md §9). Concrete implementations
/// (on-device AI, offline) live in LyricEngine; the ViewModel only ever sees this
/// protocol.
public protocol LyricProviding: Sendable {
    var kind: ProviderKind { get }
    func candidates(for spec: PhraseSpec, memory: SessionMemory) async throws(LyricProviderError) -> [LyricCandidate]

    /// Load whatever the first `candidates(for:memory:)` call would otherwise pay for,
    /// while the singer is still setting up. The on-device model costs several seconds
    /// to page in on first use, and that cost lands squarely on the first phrase of a
    /// session — the one moment the app most needs to feel instant. Providers with no
    /// warm-up cost inherit the default no-op.
    func prewarm() async
}

public extension LyricProviding {
    func prewarm() async {}
}
