import Foundation

public enum Stress: String, Sendable, Equatable, Codable {
    case strong = "S"
    case weak = "w"
}

/// The rhythmic skeleton a lyric line must fill, one slot per syllable.
public struct StressMap: Sendable, Equatable, Codable {
    public let pattern: [Stress]
    /// Maps each note index in the phrase to the syllable slot it fills (melisma notes
    /// collapse into their predecessor's slot). Empty when derived outside a phrase context.
    public let noteToSyllable: [Int]

    public init(pattern: [Stress], noteToSyllable: [Int] = []) {
        self.pattern = pattern
        self.noteToSyllable = noteToSyllable
    }

    public var count: Int { pattern.count }
    public var display: String { pattern.map(\.rawValue).joined() }

    public static func parse(_ display: String) -> StressMap? {
        var pattern: [Stress] = []
        for char in display {
            guard let stress = Stress(rawValue: String(char)) else { return nil }
            pattern.append(stress)
        }
        return StressMap(pattern: pattern)
    }
}
