/// Typed, exhaustive error taxonomy the UI switches over (docs/ARCHITECTURE.md §12).
///
/// There is deliberately no "AI unavailable" case: both generators are on-device, and
/// the premium one falls back to the offline assembler internally rather than surfacing
/// a failure, so a singer mid-take never sees an error because a guardrail balked.
public enum SessionError: Error, Sendable, Equatable {
    case micPermissionDenied
    case audioEngineFailed(String)
    case noPitchDetected
    case tooNoisy
    case persistenceFailed
}
