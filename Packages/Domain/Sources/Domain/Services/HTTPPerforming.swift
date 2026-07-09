import Foundation

/// Testability seam under the Claude HTTP client: production uses URLSession,
/// tests substitute a stub returning fixture data (docs/ARCHITECTURE.md §11).
public protocol HTTPPerforming: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
