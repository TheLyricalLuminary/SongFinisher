public enum LyricProviderError: Error, Sendable, Equatable {
    case network(String)
    case rateLimited(retryAfterSeconds: Int?)
    case invalidResponse(String)
    case unauthorized
    case cancelled
}

/// THE provider-agnostic seam (docs/ARCHITECTURE.md §9). Concrete implementations
/// (Claude, offline) live in LyricEngine; the ViewModel only ever sees this protocol.
public protocol LyricProviding: Sendable {
    var kind: ProviderKind { get }
    func candidates(for spec: PhraseSpec, memory: SessionMemory) async throws(LyricProviderError) -> [LyricCandidate]
}
