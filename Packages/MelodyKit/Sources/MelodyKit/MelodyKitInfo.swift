import Domain

/// Marker for the MelodyKit layer. Capture, ring buffer, AnalysisWorker, and the
/// DSP chain land here (see docs/ARCHITECTURE.md §8).
public enum MelodyKitInfo {
    public static let version = DomainInfo.version
}
