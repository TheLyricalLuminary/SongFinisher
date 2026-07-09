import Domain

/// Marker for the LyricEngine layer. Claude/, Offline/, UpgradingLyricProvider,
/// and RankingPipeline land here (see docs/ARCHITECTURE.md §9).
public enum LyricEngineInfo {
    public static let version = DomainInfo.version
}
