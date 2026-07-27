import Foundation

/// Budget/stress derivation for rhythm-only phrases (strummed chords), where notes are
/// onset/ring-out events and `midiNote` is a placeholder. The syllable target is the
/// onset grid scaled by the singer's chosen `SyllableDensity`; accents come from the
/// beat grid (via the existing tempo estimator) plus agogic/dynamic prominence — the
/// same three-vote philosophy as `StressMapDeriver`, minus anything pitch-derived.
public enum RhythmProsodyDeriver {
    static let metricWeight = 0.50
    static let agogicWeight = 0.25
    static let dynamicWeight = 0.25
    static let strongThreshold = 0.55
    /// A ring-out this much longer than the phrase median marks a long-note slot
    /// (same ratio the melodic path uses for long notes).
    static let longRingRatio = 1.4

    public static func deriveBudget(for phrase: Phrase, tempo: TempoEstimate?, density: SyllableDensity) -> SyllableBudget {
        let onsets = phrase.notes
        guard !onsets.isEmpty else {
            return SyllableBudget(target: 0, tolerance: 0, stressMap: StressMap(pattern: [], noteToSyllable: []))
        }

        let groups = syllableGroupSizes(onsetCount: onsets.count, density: density)

        let durations = onsets.map(\.duration)
        let medianDuration = median(durations)
        let energies = onsets.map(\.peakEnergy)
        let meanEnergy = energies.reduce(0, +) / Float(energies.count)
        let tempoReliable = tempo?.isReliable ?? false

        let prominences = onsets.map { onset in
            prominenceScore(onset, medianDuration: medianDuration, meanEnergy: meanEnergy, tempoReliable: tempoReliable)
        }

        // Each onset anchors its group's first syllable; in-between syllables are weak.
        var pattern: [Stress] = []
        var noteToSyllable: [Int] = []
        for (i, groupSize) in groups.enumerated() {
            noteToSyllable.append(pattern.count)
            pattern.append(prominences[i] >= Self.strongThreshold ? .strong : .weak)
            pattern.append(contentsOf: [Stress](repeating: .weak, count: groupSize - 1))
        }

        // Guarantee at least one strong syllable (argmax promotion, as the melodic
        // deriver does) so the stress map never degenerates to all-weak.
        if !pattern.contains(.strong), let argmax = prominences.indices.max(by: { prominences[$0] < prominences[$1] }) {
            pattern[noteToSyllable[argmax]] = .strong
        }

        // Rhythm-derived budgets are inherently estimates (the singer chose the density,
        // the grid chose the accents): never assert a zero-tolerance count, and widen
        // further when the tempo grid itself is unreliable.
        var tolerance = 1
        if let tempo, !tempo.isReliable { tolerance += 1 }
        if tempo == nil { tolerance += 1 }

        return SyllableBudget(
            target: pattern.count,
            tolerance: tolerance,
            stressMap: StressMap(pattern: pattern, noteToSyllable: noteToSyllable)
        )
    }

    /// Long ring-outs (an onset left sounding well past the median inter-onset decay)
    /// mark the syllable slots where the prompt should ask for an open vowel.
    public static func longRingSlots(for phrase: Phrase, density: SyllableDensity) -> [Int] {
        let onsets = phrase.notes
        guard !onsets.isEmpty else { return [] }
        let medianDuration = median(onsets.map(\.duration))
        guard medianDuration > 0 else { return [] }

        let groups = syllableGroupSizes(onsetCount: onsets.count, density: density)
        var anchor = 0
        var slots: [Int] = []
        for (i, groupSize) in groups.enumerated() {
            if onsets[i].duration >= medianDuration * Self.longRingRatio {
                slots.append(anchor)
            }
            anchor += groupSize
        }
        return slots
    }

    /// Per-syllable durations: each onset's ring-out split evenly across its group.
    public static func syllableDurationsMs(for phrase: Phrase, density: SyllableDensity) -> [Int] {
        let onsets = phrase.notes
        guard !onsets.isEmpty else { return [] }
        let groups = syllableGroupSizes(onsetCount: onsets.count, density: density)
        var out: [Int] = []
        for (i, groupSize) in groups.enumerated() {
            let per = onsets[i].duration * 1000 / Double(groupSize)
            out.append(contentsOf: [Int](repeating: Int(per.rounded()), count: groupSize))
        }
        return out
    }

    /// Evenly distributes `round(onsetCount × syllablesPerOnset)` syllables over the
    /// onsets (Bresenham boundaries: group i spans round(i·m)..<round((i+1)·m)), so a
    /// medium 1.5× over 4 strums yields 2-1-2-1 rather than front-loading.
    static func syllableGroupSizes(onsetCount: Int, density: SyllableDensity) -> [Int] {
        let m = density.syllablesPerOnset
        return (0..<onsetCount).map { i in
            max(1, Int((Double(i + 1) * m).rounded()) - Int((Double(i) * m).rounded()))
        }
    }

    /// Rhythm-only emotion features: tempo/density/duration/energy are real, every
    /// pitch-derived field is defaulted to neutral.
    public static func features(for phrase: Phrase, tempo: TempoEstimate?) -> EmotionFeatureVector {
        let notes = phrase.notes
        guard !notes.isEmpty else {
            return EmotionFeatureVector(
                tempoNormalized: 0.5, contourSlope: 0, pitchRangeSemitones: 0, meanIntervalSemitones: 0,
                noteDensityPerSecond: 0, meanNoteDuration: 0, energyArc: 1, endsOnDescent: 0
            )
        }

        let tempoNormalized = tempo.map { min(1, max(0, ($0.bpm - 60) / 140)) } ?? 0.5
        let density = phrase.duration > 0 ? Double(notes.count) / phrase.duration : 0
        let meanDuration = notes.map(\.duration).reduce(0, +) / Double(notes.count)
        let startEnergy = Double(notes.first?.peakEnergy ?? 1)
        let endEnergy = Double(notes.last?.peakEnergy ?? 1)
        let energyArc = startEnergy > 0.0001 ? endEnergy / startEnergy : 1

        return EmotionFeatureVector(
            tempoNormalized: tempoNormalized,
            contourSlope: 0,
            pitchRangeSemitones: 0,
            meanIntervalSemitones: 0,
            noteDensityPerSecond: density,
            meanNoteDuration: meanDuration,
            energyArc: energyArc,
            endsOnDescent: 0
        )
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
