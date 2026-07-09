public enum AIUnavailableReason: Sendable, Equatable {
    case offline
    case invalidKey
    case serverError
    case rateLimited(retryAfterSeconds: Int?)
}

/// Typed, exhaustive error taxonomy the UI switches over (docs/ARCHITECTURE.md §12).
public enum SessionError: Error, Sendable, Equatable {
    case micPermissionDenied
    case audioEngineFailed(String)
    case noPitchDetected
    case tooNoisy
    case aiUnavailable(AIUnavailableReason)
    case persistenceFailed
}
