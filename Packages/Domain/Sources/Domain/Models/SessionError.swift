/// Why generation could not produce a line. Every tier runs on the device, so there are
/// no `invalidKey` / `serverError` / `rateLimited` reasons — those describe a remote
/// service this app does not have.
public enum AIUnavailableReason: Sendable, Equatable {
    /// The premium tier is unavailable on this hardware, so drafts come from the
    /// deterministic offline assembler.
    case noOnDeviceModel
    /// Generation ran but returned nothing usable.
    case noUsableCandidates
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
