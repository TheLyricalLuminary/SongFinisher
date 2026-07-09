import Foundation

/// The syllable target a lyric line must satisfy for one phrase. `tolerance` widens
/// automatically when pitch or tempo confidence is low (docs/ARCHITECTURE.md §8), so the
/// product degrades honestly ("8–10 syllables") instead of asserting a false-precise count.
public struct SyllableBudget: Sendable, Equatable, Codable {
    public let target: Int
    public let tolerance: Int
    public let stressMap: StressMap

    public init(target: Int, tolerance: Int, stressMap: StressMap) {
        self.target = target
        self.tolerance = tolerance
        self.stressMap = stressMap
    }

    public var range: ClosedRange<Int> {
        max(1, target - tolerance)...(target + tolerance)
    }

    public func contains(_ count: Int) -> Bool { range.contains(count) }
}
