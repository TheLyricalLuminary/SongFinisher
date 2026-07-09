import Foundation

/// The 8-feature vector extracted from a completed phrase (docs/ARCHITECTURE.md §8).
public struct EmotionFeatureVector: Sendable, Equatable {
    public let tempoNormalized: Double        // 0…1 over 60–200 BPM
    public let contourSlope: Double           // semitones/second, signed
    public let pitchRangeSemitones: Double
    public let meanIntervalSemitones: Double
    public let noteDensityPerSecond: Double
    public let meanNoteDuration: Double
    public let energyArc: Double              // end RMS / start RMS
    public let endsOnDescent: Double          // 1.0 or 0.0

    public init(
        tempoNormalized: Double,
        contourSlope: Double,
        pitchRangeSemitones: Double,
        meanIntervalSemitones: Double,
        noteDensityPerSecond: Double,
        meanNoteDuration: Double,
        energyArc: Double,
        endsOnDescent: Double
    ) {
        self.tempoNormalized = tempoNormalized
        self.contourSlope = contourSlope
        self.pitchRangeSemitones = pitchRangeSemitones
        self.meanIntervalSemitones = meanIntervalSemitones
        self.noteDensityPerSecond = noteDensityPerSecond
        self.meanNoteDuration = meanNoteDuration
        self.energyArc = energyArc
        self.endsOnDescent = endsOnDescent
    }
}

/// A transparent, hand-tuned 8-label × 8-feature weight matrix (docs/ARCHITECTURE.md §8).
/// No model download; fully deterministic and testable. The top-3 distribution goes to the
/// AI layer — never a single hard label.
public enum EmotionFeatureScorer {
    private struct WeightRow {
        let tempo: Double
        let slope: Double
        let range: Double
        let interval: Double
        let density: Double
        let duration: Double
        let energyArc: Double
        let descent: Double
        let bias: Double
    }

    // Hand-tuned per docs/ARCHITECTURE.md §8: joy ← fast+major+wide+dense,
    // melancholy ← slow+falling+narrow, tension ← rising+loud+zigzag,
    // release ← cadence+falling+slowing.
    private static let weights: [Emotion: WeightRow] = [
        .joy:        WeightRow(tempo:  1.6, slope:  0.6, range:  0.9, interval:  0.4, density:  1.2, duration: -0.8, energyArc:  0.3, descent: -0.4, bias: -0.2),
        .hope:       WeightRow(tempo:  0.6, slope:  0.9, range:  0.5, interval:  0.3, density:  0.2, duration:  0.1, energyArc:  0.2, descent: -0.6, bias: -0.3),
        .tension:    WeightRow(tempo:  0.5, slope:  0.4, range:  1.1, interval:  1.0, density:  0.5, duration: -0.3, energyArc:  0.6, descent: -0.2, bias: -0.6),
        .release:    WeightRow(tempo: -0.3, slope: -0.9, range:  0.2, interval: -0.2, density: -0.3, duration:  0.5, energyArc: -0.8, descent:  1.0, bias: -0.3),
        .longing:    WeightRow(tempo: -0.5, slope:  0.3, range:  0.7, interval:  0.5, density: -0.4, duration:  0.6, energyArc:  0.1, descent: -0.3, bias:  0.0),
        .melancholy: WeightRow(tempo: -1.2, slope: -0.8, range: -0.6, interval: -0.5, density: -0.7, duration:  0.9, energyArc: -0.4, descent:  0.5, bias: -0.1),
        .nostalgia:  WeightRow(tempo: -0.4, slope:  0.1, range: -0.3, interval: -0.2, density: -0.2, duration:  0.4, energyArc:  0.0, descent:  0.1, bias: -0.2),
        .reflection: WeightRow(tempo: -1.0, slope: -0.1, range: -0.8, interval: -0.6, density: -0.9, duration:  1.0, energyArc: -0.2, descent:  0.2, bias:  0.0),
    ]

    public static func classify(_ features: EmotionFeatureVector) -> [EmotionScore] {
        var logits: [Emotion: Double] = [:]
        for (emotion, w) in weights {
            logits[emotion] = w.tempo * features.tempoNormalized
                + w.slope * features.contourSlope
                + w.range * (features.pitchRangeSemitones / 12.0)
                + w.interval * (features.meanIntervalSemitones / 6.0)
                + w.density * features.noteDensityPerSecond
                + w.duration * features.meanNoteDuration
                + w.energyArc * (features.energyArc - 1.0)
                + w.descent * features.endsOnDescent
                + w.bias
        }

        let maxLogit = logits.values.max() ?? 0
        let exps = logits.mapValues { exp($0 - maxLogit) }
        let sum = exps.values.reduce(0, +)
        guard sum > 0 else {
            return Emotion.allCases.map { EmotionScore(emotion: $0, confidence: Float(1.0 / Double(Emotion.allCases.count))) }
        }

        return Emotion.allCases
            .map { EmotionScore(emotion: $0, confidence: Float((exps[$0] ?? 0) / sum)) }
            .sortedByConfidence()
    }

    public static func features(for phrase: Phrase, tempo: TempoEstimate?) -> EmotionFeatureVector {
        let notes = phrase.notes
        guard !notes.isEmpty else {
            return EmotionFeatureVector(
                tempoNormalized: 0.5, contourSlope: 0, pitchRangeSemitones: 0, meanIntervalSemitones: 0,
                noteDensityPerSecond: 0, meanNoteDuration: 0, energyArc: 1, endsOnDescent: 0
            )
        }

        let tempoNormalized = tempo.map { min(1, max(0, ($0.bpm - 60) / 140)) } ?? 0.5

        let pitches = notes.map(\.midiNote)
        let range = (pitches.max() ?? 0) - (pitches.min() ?? 0)

        var intervals: [Double] = []
        for i in 1..<notes.count { intervals.append(abs(notes[i].midiNote - notes[i - 1].midiNote)) }
        let meanInterval = intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count)

        let slope: Double
        if let first = pitches.first, let last = pitches.last, phrase.duration > 0 {
            slope = (last - first) / phrase.duration
        } else {
            slope = 0
        }

        let density = phrase.duration > 0 ? Double(notes.count) / phrase.duration : 0
        let meanDuration = notes.map(\.duration).reduce(0, +) / Double(notes.count)

        let startEnergy = Double(notes.first?.peakEnergy ?? 1)
        let endEnergy = Double(notes.last?.peakEnergy ?? 1)
        let energyArc = startEnergy > 0.0001 ? endEnergy / startEnergy : 1

        let endsOnDescent: Double = {
            guard notes.count >= 2 else { return 0 }
            let tail = notes.suffix(3)
            let tailPitches = tail.map(\.midiNote)
            guard let first = tailPitches.first, let last = tailPitches.last else { return 0 }
            return last < first ? 1 : 0
        }()

        return EmotionFeatureVector(
            tempoNormalized: tempoNormalized,
            contourSlope: slope,
            pitchRangeSemitones: range,
            meanIntervalSemitones: meanInterval,
            noteDensityPerSecond: density,
            meanNoteDuration: meanDuration,
            energyArc: energyArc,
            endsOnDescent: endsOnDescent
        )
    }
}
