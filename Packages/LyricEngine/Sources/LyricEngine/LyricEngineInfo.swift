import Domain

/// Marker for the LyricEngine layer. The Foundation Models provider, the offline
/// assembler, the lexicon, sparks, and ranking land here (docs/ARCHITECTURE.md §9).
public enum LyricEngineInfo {
    public static let version = DomainInfo.version
}
