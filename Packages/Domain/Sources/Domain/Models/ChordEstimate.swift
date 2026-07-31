import Foundation

/// The harmonic quality matched against a chromagram (see `ChordDetector` in MelodyKit).
/// Deliberately a small, singable-song-relevant set — this isn't a full jazz-chord
/// vocabulary, just enough to distinguish major/minor "color" and the two common
/// sevenths/altered triads that shift emotional read (docs/ARCHITECTURE.md §8 companion:
/// chord informs mood the same way tempo informs stress).
public enum ChordQuality: String, Sendable, Equatable, Codable, CaseIterable {
    case major
    case minor
    case dominant7
    case diminished
    case augmented

    /// Minor and diminished chords share the "darker" emotional pull used to bias
    /// `EmotionFeatureScorer` — augmented/dominant7 are treated as tension, not sadness.
    public var isMinorLike: Bool {
        self == .minor || self == .diminished
    }

    /// Interval template in semitones from the root, used for chroma cosine-similarity
    /// matching in `ChordDetector`.
    public var intervals: [Int] {
        switch self {
        case .major: [0, 4, 7]
        case .minor: [0, 3, 7]
        case .dominant7: [0, 4, 7, 10]
        case .diminished: [0, 3, 6]
        case .augmented: [0, 4, 8]
        }
    }
}

/// A detected harmonic chord over a short analysis window (see `ChordDetector`). `root` is
/// a pitch class 0–11 (0 = C), matching standard MIDI-mod-12 convention used elsewhere in
/// MelodyKit's pitch code.
public struct ChordEstimate: Sendable, Equatable, Codable {
    public let root: Int
    public let quality: ChordQuality
    public let confidence: Float

    public init(root: Int, quality: ChordQuality, confidence: Float) {
        // Normalize defensively so callers can pass any MIDI note number, not just 0-11.
        self.root = ((root % 12) + 12) % 12
        self.quality = quality
        self.confidence = confidence
    }

    /// Below this confidence a chord read is too noisy to trust — callers should treat the
    /// chord as absent (mirrors `TempoEstimate.reliableConfidenceThreshold`).
    public static let reliableConfidenceThreshold: Float = 0.55

    public var isReliable: Bool { confidence >= Self.reliableConfidenceThreshold }

    private static let rootNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// A short chord symbol like "C", "Am", "G7", "Bdim", "D+" — for UI display and debug
    /// logging, not for harmonic analysis.
    public var displayName: String {
        let name = Self.rootNames[root]
        switch quality {
        case .major: return name
        case .minor: return "\(name)m"
        case .dominant7: return "\(name)7"
        case .diminished: return "\(name)dim"
        case .augmented: return "\(name)+"
        }
    }

    private static let spokenRootNames = [
        "C", "C sharp", "D", "D sharp", "E", "F", "F sharp", "G", "G sharp", "A", "A sharp", "B",
    ]

    /// VoiceOver-friendly name: "Am" reads as the word "am", so accessibility labels use
    /// the fully spelled form ("A minor", "G dominant seventh") instead of the symbol.
    public var spokenName: String {
        let name = Self.spokenRootNames[root]
        switch quality {
        case .major: return "\(name) major"
        case .minor: return "\(name) minor"
        case .dominant7: return "\(name) dominant seventh"
        case .diminished: return "\(name) diminished"
        case .augmented: return "\(name) augmented"
        }
    }
}
