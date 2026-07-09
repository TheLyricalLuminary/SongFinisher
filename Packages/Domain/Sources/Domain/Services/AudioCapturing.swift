public protocol AudioCapturing: Sendable {
    var state: AsyncStream<CaptureState> { get }
    func start() async throws(CaptureError) -> AsyncStream<AudioChunk>
    func stop() async
}
