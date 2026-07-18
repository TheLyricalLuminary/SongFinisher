import Foundation

/// How many syllables a rhythm-only phrase asks for per strum/onset. Chords carry no
/// melody line to count syllables from, so the singer picks the lyric density they
/// intend to sing over the pocket; the onset grid supplies the accents.
public enum SyllableDensity: String, Sendable, Equatable, Codable, CaseIterable {
    case sparse, medium, dense

    /// Syllables requested per onset. Fractional values distribute evenly across the
    /// phrase (a 1.5 over 4 onsets yields 6 syllables, alternating 1 and 2 per onset).
    public var syllablesPerOnset: Double {
        switch self {
        case .sparse: 1.0
        case .medium: 1.5
        case .dense: 2.0
        }
    }
}
