import Testing
import Foundation
import Domain
@testable import MelodyKit

@Suite struct YINPitchDetectorTests {

    private func detectMedianPitch(_ samples: [Float]) -> Double? {
        let detector = YINPitchDetector()
        var voiced: [Double] = []
        var offset = 0
        while offset + YINPitchDetector.windowSize <= samples.count {
            let window = Array(samples[offset..<offset + YINPitchDetector.windowSize])
            let frame = detector.process(window: window, time: Double(offset) / TestSignals.sampleRate)
            if let f = frame.frequencyHz { voiced.append(f) }
            offset += AnalysisChain.hopSize
        }
        guard !voiced.isEmpty else { return nil }
        return voiced.sorted()[voiced.count / 2]
    }

    @Test func pureA440IsDetectedWithinHalfAHertz() {
        let samples = TestSignals.tone(frequency: 440, duration: 0.5)
        let pitch = detectMedianPitch(samples)
        #expect(pitch != nil)
        if let pitch { #expect(abs(pitch - 440) < 0.5) }
    }

    @Test func silenceIsUnvoiced() {
        #expect(detectMedianPitch(TestSignals.silence(duration: 0.5)) == nil)
    }

    @Test func harmonicMixDetectsTheFundamentalNotTheOctave() {
        // 220 Hz fundamental + strong 440 Hz second harmonic: the classic octave-error trap.
        let count = Int(0.5 * TestSignals.sampleRate)
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / TestSignals.sampleRate
            samples[i] = 0.4 * Float(sin(2 * .pi * 220 * t)) + 0.3 * Float(sin(2 * .pi * 440 * t))
        }
        let pitch = detectMedianPitch(samples)
        #expect(pitch != nil)
        if let pitch { #expect(abs(pitch - 220) < 2.0) }
    }

    @Test("pitch across the melody range stays within ±20 cents", arguments: [82.4, 110.0, 196.0, 261.6, 440.0, 784.0])
    func sweepAccuracy(frequency: Double) {
        let samples = TestSignals.tone(frequency: frequency, duration: 0.4)
        guard let pitch = detectMedianPitch(samples) else {
            Issue.record("no pitch detected at \(frequency) Hz")
            return
        }
        let cents = 1200.0 * log2(pitch / frequency)
        #expect(abs(cents) < 20.0)
    }

    @Test func confidenceIsHighOnCleanTonesAndReportedInFrames() {
        let detector = YINPitchDetector()
        let samples = TestSignals.tone(frequency: 330, duration: 0.3)
        let window = Array(samples[1000..<1000 + YINPitchDetector.windowSize])
        let frame = detector.process(window: window, time: 0)
        #expect(frame.confidence > 0.9)
    }

    @Test func deterministicAcrossRuns() {
        let samples = TestSignals.melody([(60, 0.3), (64, 0.3), (67, 0.4)])
        let a = TestSignals.analyze(samples)
        let b = TestSignals.analyze(samples)
        #expect(a.pitchFrames == b.pitchFrames)
        #expect(a.phrases.map(\.notes.count) == b.phrases.map(\.notes.count))
    }
}
