import Foundation

/// Derives the syllable budget + stress map from a completed phrase's notes
/// (docs/ARCHITECTURE.md §8). One slot per non-melisma note; prominence is a weighted vote
/// of metric, agogic, dynamic, and pitch-peak accent. Confidence widens tolerance instead of
/// asserting a false-precise budget.
public enum StressMapDeriver {
    static let metricWeight = 0.45
    static let agogicWeight = 0.30
    static let dynamicWeight = 0.25
    static let strongThreshold = 0.55

    public static func deriveBudget(for phrase: Phrase, tempo: TempoEstimate?) -> SyllableBudget {
        let notes = phrase.syllableBearingNotes
        let noteToSyllable = buildNoteToSyllableMap(phrase.notes)

        guard !notes.isEmpty else {
            return SyllableBudget(target: 0, tolerance: 0, stressMap: StressMap(pattern: [], noteToSyllable: noteToSyllable))
        }

        let durations = notes.map(\.duration)
        let medianDuration = median(durations)
        let energies = notes.map(\.peakEnergy)
        let meanEnergy = energies.reduce(0, +) / Float(energies.count)

        let tempoReliable = tempo?.isReliable ?? false

        let prominences = notes.map { prominenceScore($0, medianDuration: medianDuration, meanEnergy: meanEnergy, tempoReliable: tempoReliable) }
        var pattern = prominences.map { $0 >= strongThreshold ? Stress.strong : Stress.weak }

        // Guarantee at least one strong syllable per phrase (argmax promotion).
        if !pattern.contains(.strong), let argmax = prominences.indices.max(by: { prominences[$0] < prominences[$1] }) {
            pattern[argmax] = .strong
        }

        let tolerance = confidenceBasedTolerance(phrase: phrase, tempo: tempo)
        let stressMap = StressMap(pattern: pattern, noteToSyllable: noteToSyllable)
        return SyllableBudget(target: pattern.count, tolerance: tolerance, stressMap: stressMap)
    }

    /// Melisma notes fold into the syllable slot of the preceding syllable-bearing note.
    static func buildNoteToSyllableMap(_ notes: [NoteEvent]) -> [Int] {
        var map: [Int] = []
        var slot = -1
        for note in notes {
            if !note.isMelisma { slot += 1 }
            map.append(max(0, slot))
        }
        return map
    }

    /// Low pitch or tempo confidence widens tolerance rather than asserting a wrong map
    /// (docs/ARCHITECTURE.md §1, §8: "syllables 8–10" instead of a false-precise 9).
    static func confidenceBasedTolerance(phrase: Phrase, tempo: TempoEstimate?) -> Int {
        var tolerance = 0
        if phrase.pitchConfidence < 0.6 { tolerance += 1 }
        if let tempo, !tempo.isReliable { tolerance += 1 }
        return tolerance
    }

    private static func prominenceScore(_ note: NoteEvent, medianDuration: TimeInterval, meanEnergy: Float, tempoReliable: Bool) -> Double {
        let metric = tempoReliable ? Double(note.beatStrength) : 0.5
        let agogic = medianDuration > 0 ? min(1, note.duration / medianDuration / 2) : 0.5
        let dynamic = meanEnergy > 0 ? min(1, Double(note.peakEnergy / meanEnergy) / 2) : 0.5
        return metricWeight * metric + agogicWeight * agogic + dynamicWeight * dynamic
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
