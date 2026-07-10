import Testing
import Foundation
import Domain
@testable import MelodyKit

@Suite struct SegmentationTests {

    @Test func threeNoteMelodySeparatedBySilenceYieldsOnePhraseWithThreeNotes() {
        var samples = TestSignals.melody([(60, 0.35), (64, 0.35), (67, 0.5)])
        samples.append(contentsOf: TestSignals.silence(duration: 0.6))
        let phrases = TestSignals.analyze(samples).phrases
        #expect(phrases.count == 1)
        if let phrase = phrases.first {
            #expect(phrase.notes.count == 3)
        }
    }

    @Test func breathGapSplitsTwoPhrases() {
        // Each phrase must clear the 700 ms / 2-note minimums on its own: 0.4 s + 0.4 s
        // notes per phrase, with a 500 ms breath (> the 350 ms boundary) between them.
        var samples = TestSignals.melody([(60, 0.4), (62, 0.4)])
        samples.append(contentsOf: TestSignals.silence(duration: 0.5))
        samples.append(contentsOf: TestSignals.melody([(64, 0.4), (65, 0.4)]))
        samples.append(contentsOf: TestSignals.silence(duration: 0.6))
        let phrases = TestSignals.analyze(samples).phrases
        #expect(phrases.count == 2)
    }

    @Test func shortArticulationGapDoesNotSplitAPhrase() {
        // 30 ms inter-note gaps are articulation, not phrase boundaries.
        var samples = TestSignals.melody([(60, 0.3), (62, 0.3), (64, 0.3)], gap: 0.03)
        samples.append(contentsOf: TestSignals.silence(duration: 0.6))
        let phrases = TestSignals.analyze(samples).phrases
        #expect(phrases.count == 1)
    }

    @Test func singleBlipIsDiscardedAsNoise() {
        // One 150 ms blip: fails both the 2-note and 700 ms phrase minimums.
        var samples = TestSignals.tone(frequency: 440, duration: 0.15)
        samples.append(contentsOf: TestSignals.silence(duration: 0.8))
        let phrases = TestSignals.analyze(samples).phrases
        #expect(phrases.isEmpty)
    }

    @Test func phraseDurationAndBoundsAreSane() {
        var samples = TestSignals.melody([(60, 0.4), (67, 0.4)])
        samples.append(contentsOf: TestSignals.silence(duration: 0.6))
        guard let phrase = TestSignals.analyze(samples).phrases.first else {
            Issue.record("no phrase detected")
            return
        }
        #expect(phrase.start >= 0)
        #expect(phrase.duration > 0.5)
        #expect(phrase.duration < 2.0)
        #expect(phrase.pitchConfidence > 0.5)
    }

    @Test func notesCarryReasonablePitches() {
        var samples = TestSignals.melody([(60, 0.35), (72, 0.35)])
        samples.append(contentsOf: TestSignals.silence(duration: 0.6))
        guard let phrase = TestSignals.analyze(samples).phrases.first, phrase.notes.count >= 2 else {
            Issue.record("expected 2 notes")
            return
        }
        #expect(abs(phrase.notes[0].midiNote - 60) < 1.0)
        #expect(abs(phrase.notes[1].midiNote - 72) < 1.0)
    }

    @Test func legatoGlideProducesMelismaFlaggedNote() {
        // Continuous tone gliding up 3 semitones over 100 ms with no articulation gap
        // and no amplitude dip — a true legato slur. A hard frequency step would be
        // spectrally indistinguishable from a re-articulation (a genuine energy onset);
        // the ramp keeps flux low so only the pitch-jump path can split it, and the
        // successor must be flagged melisma.
        let count = Int(0.8 * TestSignals.sampleRate)
        let glideStart = Int(0.35 * TestSignals.sampleRate)
        let glideEnd = Int(0.45 * TestSignals.sampleRate)
        var samples = [Float](repeating: 0, count: count)
        var phase = 0.0
        for i in 0..<count {
            let f: Double
            if i < glideStart {
                f = 261.63                      // C4
            } else if i >= glideEnd {
                f = 311.13                      // D#4
            } else {
                let t = Double(i - glideStart) / Double(glideEnd - glideStart)
                f = 261.63 + (311.13 - 261.63) * t
            }
            phase += 2.0 * .pi * f / TestSignals.sampleRate
            samples[i] = 0.5 * Float(sin(phase))
        }
        samples.append(contentsOf: TestSignals.silence(duration: 0.6))
        guard let phrase = TestSignals.analyze(samples).phrases.first else {
            Issue.record("no phrase detected")
            return
        }
        #expect(phrase.notes.count == 2)
        #expect(phrase.notes.contains { $0.isMelisma })
    }

    @Test func endToEndPipelineIsDeterministic() {
        var samples = TestSignals.melody([(62, 0.3), (65, 0.3), (69, 0.3), (65, 0.5)])
        samples.append(contentsOf: TestSignals.silence(duration: 0.7))
        let a = TestSignals.analyze(samples).phrases
        let b = TestSignals.analyze(samples).phrases
        #expect(a.count == b.count)
        #expect(a.map { $0.notes.map(\.midiNote) } == b.map { $0.notes.map(\.midiNote) })
    }
}
