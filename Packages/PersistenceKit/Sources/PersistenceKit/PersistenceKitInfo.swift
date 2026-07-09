import Domain

/// Marker for the PersistenceKit layer. SongStore (@ModelActor), SDModels,
/// DomainMapping, and KeychainStore land here (see docs/ARCHITECTURE.md §7).
public enum PersistenceKitInfo {
    public static let version = DomainInfo.version
}
