public protocol PermissionChecking: Sendable {
    func currentMicPermission() async -> MicPermission
    func requestMicPermission() async -> MicPermission
}
