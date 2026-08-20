import Testing
import Foundation
@testable import Domain

@Suite struct EmotionFeatureScorerTests {

    @Test func distributionAlwaysSumsToApproximatelyOne() {
        let features = EmotionFeatureVector(
            tempoNormalized: 0.5, contourSlope: 0, pitchRangeSemitones: 5, meanIntervalSemitones: 2,
            noteDensityPerSecond: 1.5, meanNoteDuration: 0.4, energyArc: 1.0, endsOnDescent: 0
        )
        let scores = EmotionFeatureScorer.classify(features)
        #expect(scores.count == Emotion.allCases.count)
        let sum = scores.reduce(0.0) { $0 + Double($1.confidence) }
        #expect(abs(sum - 1.0) < 0.001)
    }

    @Test func distributionIsSortedDescending() {
        let features = EmotionFeatureVector(
            tempoNormalized: 0.8, contourSlope: 1, pitchRangeSemitones: 10, meanIntervalSemitones: 3,
            noteDensityPerSecond: 2.5, meanNoteDuration: 0.2, energyArc: 1.1, endsOnDescent: 0
        )
        let scores = EmotionFeatureScorer.classify(features)
        for i in 1..<scores.count {
            #expect(scores[i - 1].confidence >= scores[i].confidence)
        }
    }

    @Test("fast+major-leaning+wide+dense+staccato features top-rank joy or hope")
    func fastBrightFeaturesFavorJoy() {
        let features = EmotionFeatureVector(
            tempoNormalized: 0.95,
            contourSlope: 3.0,
            pitchRangeSemitones: 14,
            meanIntervalSemitones: 3,
            noteDensityPerSecond: 3.5,
            meanNoteDuration: 0.15,
            energyArc: 1.2,
            endsOnDescent: 0
        )
        let top = EmotionFeatureScorer.classify(features).first!.emotion
        #expect(top == .joy || top == .hope)
    }

    @Test("slow+narrow+legato+sustained features top-rank melancholy or reflection")
    func slowDarkFeaturesFavorMelancholy() {
        // Deliberately mild slope/descent so this doesn't also trigger release's
        // cadence-detection weights (covered separately below) — isolates the
        // slow+narrow+legato signal that distinguishes melancholy/reflection.
        let features = EmotionFeatureVector(
            tempoNormalized: 0.05,
            contourSlope: -0.2,
            pitchRangeSemitones: 2,
            meanIntervalSemitones: 0.7,
            noteDensityPerSecond: 0.25,
            meanNoteDuration: 1.4,
            energyArc: 0.98,
            endsOnDescent: 0
        )
        let top = EmotionFeatureScorer.classify(features).first!.emotion
        #expect(top == .melancholy || top == .reflection)
    }

    @Test("cadence-ending descending-slowing features top-rank release")
    func cadentialFeaturesFavorRelease() {
        let features = EmotionFeatureVector(
            tempoNormalized: 0.3,
            contourSlope: -2.0,
            pitchRangeSemitones: 6,
            meanIntervalSemitones: 2,
            noteDensityPerSecond: 0.6,
            meanNoteDuration: 0.8,
            energyArc: 0.3,
            endsOnDescent: 1
        )
        let top = EmotionFeatureScorer.classify(features).first!.emotion
        #expect(top == .release)
    }

    @Test func featuresFromEmptyPhraseAreNeutral() {
        let phrase = Phrase(index: 0, start: 0, end: 0, notes: [], endsWithCadence: false, pitchConfidence: 0)
        let features = EmotionFeatureScorer.features(for: phrase, tempo: nil)
        #expect(features.tempoNormalized == 0.5)
        #expect(features.contourSlope == 0)
    }

    @Test func featuresDetectDescendingTail() {
        let notes = [
            NoteEvent(onset: 0, duration: 0.3, midiNote: 60, peakEnergy: 0.5, beatStrength: 0.5),
            NoteEvent(onset: 0.3, duration: 0.3, midiNote: 64, peakEnergy: 0.5, beatStrength: 0.5),
            NoteEvent(onset: 0.6, duration: 0.3, midiNote: 55, peakEnergy: 0.3, beatStrength: 0.5),
        ]
        let phrase = Phrase(index: 0, start: 0, end: 0.9, notes: notes, endsWithCadence: true, pitchConfidence: 0.9)
        let features = EmotionFeatureScorer.features(for: phrase, tempo: nil)
        #expect(features.endsOnDescent == 1.0)
    }

    @Test func featuresComputeTempoNormalizedRange() {
        let notes = [NoteEvent(onset: 0, duration: 0.5, midiNote: 60, peakEnergy: 0.5, beatStrength: 0.5)]
        let phrase = Phrase(index: 0, start: 0, end: 0.5, notes: notes, endsWithCadence: true, pitchConfidence: 0.9)
        let slow = TempoEstimate(bpm: 60, confidence: 0.9, beatPhase: 0)
        let fast = TempoEstimate(bpm: 200, confidence: 0.9, beatPhase: 0)
        #expect(EmotionFeatureScorer.features(for: phrase, tempo: slow).tempoNormalized == 0.0)
        #expect(EmotionFeatureScorer.features(for: phrase, tempo: fast).tempoNormalized == 1.0)
    }

    // MARK: - Chord bias (docs/ARCHITECTURE.md §8 companion: harmony as a bonus signal)

    /// A feature vector with every shape-driven term zeroed out (flat contour, zero pitch
    /// range/interval/density, no energy arc, no cadence) so any emotional lean in these
    /// tests comes from the chord bias alone, not from the melody. It isn't perfectly
    /// balanced — joy still edges out on tempo/bias terms alone — but that's exactly the
    /// point: a reliable minor chord should be enough by itself to flip the top emotion
    /// away from joy, the same way a reliable major chord reinforces it.
    private static let neutralFeatures = EmotionFeatureVector(
        tempoNormalized: 0.5, contourSlope: 0, pitchRangeSemitones: 0, meanIntervalSemitones: 0,
        noteDensityPerSecond: 0, meanNoteDuration: 0.5, energyArc: 1.0, endsOnDescent: 0
    )

    @Test func reliableMajorChordTiltsTowardJoyOrHope() {
        let chord = ChordEstimate(root: 0, quality: .major, confidence: 0.9)
        let top = EmotionFeatureScorer.classify(Self.neutralFeatures, chord: chord).first!.emotion
        #expect(top == .joy || top == .hope)
    }

    @Test func reliableMinorChordTiltsTowardMelancholyOrLongingOrReflection() {
        let chord = ChordEstimate(root: 9, quality: .minor, confidence: 0.9)
        let top = EmotionFeatureScorer.classify(Self.neutralFeatures, chord: chord).first!.emotion
        #expect(top == .melancholy || top == .longing || top == .reflection)
    }

    @Test func unreliableChordDoesNotShiftTheDistribution() {
        // Below `ChordEstimate.reliableConfidenceThreshold` — should be ignored entirely,
        // producing the exact same distribution as passing no chord at all.
        let chord = ChordEstimate(root: 9, quality: .minor, confidence: 0.1)
        let withChord = EmotionFeatureScorer.classify(Self.neutralFeatures, chord: chord)
        let withoutChord = EmotionFeatureScorer.classify(Self.neutralFeatures, chord: nil)
        for (a, b) in zip(withChord, withoutChord) {
            #expect(a.emotion == b.emotion)
            #expect(abs(a.confidence - b.confidence) < 0.0001)
        }
    }

    @Test func majorAndMinorChordsProduceDifferentDistributions() {
        let major = ChordEstimate(root: 0, quality: .major, confidence: 0.9)
        let minor = ChordEstimate(root: 0, quality: .minor, confidence: 0.9)
        let majorScores = EmotionFeatureScorer.classify(Self.neutralFeatures, chord: major)
        let minorScores = EmotionFeatureScorer.classify(Self.neutralFeatures, chord: minor)
        let majorJoy = majorScores.first { $0.emotion == .joy }!.confidence
        let minorJoy = minorScores.first { $0.emotion == .joy }!.confidence
        #expect(majorJoy > minorJoy)
    }
}
