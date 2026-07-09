import Foundation

public enum CaptureState: Sendable, Equatable {
    case idle
    case listening
    case paused
    case failed(String)
}

/// A chunk of mono 16 kHz audio yielded by `AudioCapturing` (docs/ARCHITECTURE.md §8, ~64 ms).
public struct AudioChunk: Sendable, Equatable {
    public let samples: [Float]
    public let time: TimeInterval

    public init(samples: [Float], time: TimeInterval) {
        self.samples = samples
        self.time = time
    }
}

public enum CaptureError: Error, Sendable, Equatable {
    case permissionDenied
    case engineStartFailed(String)
    case routeUnavailable
}

public enum MicPermission: Sendable, Equatable {
    case undetermined
    case granted
    case denied
}
