import Testing
import Foundation
@testable import MelodyKit
import Domain

@Suite struct PolyphonyDetectorTests {
    private let binWidth = 16_000.0 / 1024.0  // 15.625 Hz

    /// A 512-bin magnitude spectrum with symmetric peaks at the given (bin, magnitude)
    /// pairs — parabolic refinement resolves each to exactly bin × binWidth.
    private func spectrum(peaks: [(bin: Int, magnitude: Float)]) -> [Float] {
        var m = [Float](repeating: 0, count: 512)
        for peak in peaks {
            m[peak.bin] = peak.magnitude
            m[peak.bin - 1] = max(m[peak.bin - 1], peak.magnitude * 0.4)
            m[peak.bin + 1] = max(m[peak.bin + 1], peak.magnitude * 0.4)
        }
        return m
    }

    private func voicedFrame(f0: Double, confidence: Float = 0.9, rms: Float = 0.5) -> PitchFrame {
        PitchFrame(time: 0, frequencyHz: f0, midiNote: 69 + 12 * log2(f0 / 440), rmsEnergy: rms, confidence: confidence)
    }

    private func unvoicedFrame(rms: Float = 0.5) -> PitchFrame {
        PitchFrame(time: 0, frequencyHz: nil, midiNote: nil, rmsEnergy: rms, confidence: 0.1)
    }

    // MARK: - Frame classification

    @Test func harmonicSeriesWithConfidentYINIsMonophonic() {
        let detector = PolyphonyDetector()
        // Root at bin 6 (93.75 Hz) with harmonics at 2×, 3×, 4×.
        let m = spectrum(peaks: [(6, 1.0), (12, 0.7), (18, 0.5), (24, 0.3)])
        #expect(!detector.classifyFrame(magnitudes: m, frame: voicedFrame(f0: 6 * binWidth)))
    }

    @Test func missingFundamentalIsStillMonophonic() {
        // The fundamental is absent from the spectrum but YIN's time-domain period
        // finds it anyway — every visible partial is an integer multiple of that f0.
        let detector = PolyphonyDetector()
        let m = spectrum(peaks: [(12, 1.0), (18, 0.8), (24, 0.5), (30, 0.4)])
        #expect(!detector.classifyFrame(magnitudes: m, frame: voicedFrame(f0: 6 * binWidth)))
    }

    @Test func chordAgainstConfidentYINRootIsPolyphonic() {
        // Root + octave are harmonic, but the fifth (1.5×) and the tenth (2.5×) are
        // not integer multiples of YIN's f0 — the chord-tone signature.
        let detector = PolyphonyDetector()
        let m = spectrum(peaks: [(6, 1.0), (9, 0.8), (12, 0.6), (15, 0.5)])
        #expect(detector.classifyFrame(magnitudes: m, frame: voicedFrame(f0: 6 * binWidth)))
    }

    @Test func yinCollapseWithManyPeaksIsPolyphonic() {
        // The strum attack: strong signal, no single period, spectrum full of peaks.
        let detector = PolyphonyDetector()
        let m = spectrum(peaks: [(6, 1.0), (9, 0.9), (13, 0.7), (17, 0.6), (21, 0.5)])
        #expect(detector.classifyFrame(magnitudes: m, frame: unvoicedFrame()))
    }

    @Test func yinCollapseWithFewPeaksIsNotPolyphonic() {
        // A breathy/consonant frame: unvoiced but spectrally sparse — not a chord.
        let detector = PolyphonyDetector()
        let m = spectrum(peaks: [(6, 1.0), (12, 0.5), (18, 0.3)])
        #expect(!detector.classifyFrame(magnitudes: m, frame: unvoicedFrame()))
    }

    @Test func vibratoDetuningStaysMonophonic() {
        // Vibrato moves f0 and every harmonic together, so YIN's reported f0 can sit
        // up to ±50 cents (≈ ±3%) off the bin-quantized partials — still inside the
        // 6%-of-root harmonic tolerance, so no partial reads as inharmonic.
        let detector = PolyphonyDetector()
        let detunedF0 = 6 * binWidth * pow(2.0, 50.0 / 1200.0)
        let m = spectrum(peaks: [(6, 1.0), (12, 0.7), (18, 0.5)])
        #expect(!detector.classifyFrame(magnitudes: m, frame: voicedFrame(f0: detunedF0)))
    }

    // MARK: - Mode smoothing

    @Test func sustainedChordFramesEnterRhythmicMode() {
        let detector = PolyphonyDetector()
        let chord = spectrum(peaks: [(6, 1.0), (9, 0.8), (12, 0.6), (15, 0.5), (21, 0.4)])
        var transitions: [InputMode] = []
        for _ in 0..<40 {
            if let mode = detector.ingest(magnitudes: chord, frame: unvoicedFrame()) {
                transitions.append(mode)
            }
        }
        #expect(transitions == [.rhythmic])
        #expect(detector.mode == .rhythmic)
    }

    @Test func returningToHummingExitsRhythmicMode() {
        let detector = PolyphonyDetector()
        let chord = spectrum(peaks: [(6, 1.0), (9, 0.8), (12, 0.6), (15, 0.5), (21, 0.4)])
        let hum = spectrum(peaks: [(14, 1.0), (28, 0.5)])
        for _ in 0..<40 { _ = detector.ingest(magnitudes: chord, frame: unvoicedFrame()) }
        #expect(detector.mode == .rhythmic)

        var transitions: [InputMode] = []
        for _ in 0..<60 {
            if let mode = detector.ingest(magnitudes: hum, frame: voicedFrame(f0: 14 * binWidth)) {
                transitions.append(mode)
            }
        }
        #expect(transitions == [.melodic])
        #expect(detector.mode == .melodic)
    }

    @Test func silenceNeverVotes() {
        let detector = PolyphonyDetector()
        let chord = spectrum(peaks: [(6, 1.0), (9, 0.8), (12, 0.6), (15, 0.5), (21, 0.4)])
        for _ in 0..<200 {
            let flipped = detector.ingest(magnitudes: chord, frame: unvoicedFrame(rms: 0.0001))
            #expect(flipped == nil)
        }
        #expect(detector.mode == .melodic)
    }

    @Test func briefChordBlipDoesNotFlipMode() {
        let detector = PolyphonyDetector()
        let chord = spectrum(peaks: [(6, 1.0), (9, 0.8), (12, 0.6), (15, 0.5), (21, 0.4)])
        let hum = spectrum(peaks: [(14, 1.0), (28, 0.5)])
        // 10 chord frames (a single accidental strum) drowned in hummed frames.
        for _ in 0..<30 { _ = detector.ingest(magnitudes: hum, frame: voicedFrame(f0: 14 * binWidth)) }
        for _ in 0..<10 { _ = detector.ingest(magnitudes: chord, frame: unvoicedFrame()) }
        for _ in 0..<30 { _ = detector.ingest(magnitudes: hum, frame: voicedFrame(f0: 14 * binWidth)) }
        #expect(detector.mode == .melodic)
    }
}
