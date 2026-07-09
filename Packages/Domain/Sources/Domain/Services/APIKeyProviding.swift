public protocol APIKeyProviding: Sendable {
    func anthropicKey() throws -> String
}
