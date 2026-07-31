import Testing
import Foundation
import Domain
@testable import MelodyKit

/// Synthesized chord fixtures give exact ground truth (docs/ARCHITECTURE.md §11) — pure
/// sine tones summed with no harmonics, so the chroma detector's match should be
/// unambiguous.
@Suite struct ChordDetectorTests {

    @Test func detectsSustainedCMajorTriad() {
        let samples = TestSignals.pureToneChord(midiNotes: [60, 64, 67], duration: 2.0)  // C E G
        let chords = TestSignals.analyze(samples).chordUpdates
        guard let last = chords.last else {
            Issue.record("no chord estimate produced")
            return
        }
        #expect(last.isReliable)
        #expect(last.root == 0)
        #expect(last.quality == .major)
    }

    @Test func detectsSustainedAMinorTriad() {
        let samples = TestSignals.pureToneChord(midiNotes: [57, 60, 64], duration: 2.0)  // A C E
        let chords = TestSignals.analyze(samples).chordUpdates
        guard let last = chords.last else {
            Issue.record("no chord estimate produced")
            return
        }
        #expect(last.isReliable)
        #expect(last.root == 9)
        #expect(last.quality == .minor)
    }

    @Test func detectsSustainedGDominant7() {
        let samples = TestSignals.pureToneChord(midiNotes: [55, 59, 62, 65], duration: 2.0)  // G B D F
        let chords = TestSignals.analyze(samples).chordUpdates
        guard let last = chords.last else {
            Issue.record("no chord estimate produced")
            return
        }
        #expect(last.isReliable)
        #expect(last.root == 7)
        #expect(last.quality == .dominant7)
    }

    @Test func detectsSustainedBDiminishedTriad() {
        let samples = TestSignals.pureToneChord(midiNotes: [59, 62, 65], duration: 2.0)  // B D F
        let chords = TestSignals.analyze(samples).chordUpdates
        guard let last = chords.last else {
            Issue.record("no chord estimate produced")
            return
        }
        #expect(last.isReliable)
        #expect(last.root == 11)
        #expect(last.quality == .diminished)
    }

    @Test func silenceProducesNoChordEstimate() {
        let samples = TestSignals.silence(duration: 1.5)
        let chords = TestSignals.analyze(samples).chordUpdates
        #expect(chords.isEmpty)
    }

    @Test func resetClearsPendingChordState() {
        let detector = ChordDetector()
        let chordSamples = TestSignals.pureToneChord(midiNotes: [60, 64, 67], duration: 1.0)
        var produced = false
        // Feed hop-sized chunks the way AnalysisChain does.
        var offset = 0
        while offset + 160 <= chordSamples.count {
            let hop = Array(chordSamples[offset..<(offset + 160)])
            if detector.ingest(hopSamples: hop) != nil { produced = true }
            offset += 160
        }
        #expect(produced)
        #expect(detector.current != nil)

        detector.reset()
        #expect(detector.current == nil)
    }
}
