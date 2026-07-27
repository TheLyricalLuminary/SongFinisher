import Testing
import Foundation
@testable import MelodyKit
import Domain

/// End-to-end coverage of the hybrid melodic/rhythmic chain: strummed chords must
/// route through the rhythm path (isRhythmOnly phrases from the onset pocket), single
/// lines must keep the YIN path unchanged, and mode handoffs must not drop phrases.
@Suite struct HybridModeTests {
    /// E-major guitar voicing (E2 B2 E3 G#3 B3) — the fifth (1.5×) and major third
    /// (2.52× the root) are the classic non-integer partials no single F0 explains.
    private let eMajor: [Double] = [40, 47, 52, 56, 59]

    @Test func strummedChordsProduceARhythmOnlyPhrase() {
        var samples = TestSignals.strummedChord(midiNotes: eMajor, strums: 8)
        samples.append(contentsOf: TestSignals.silence(duration: 0.6))
        let events = TestSignals.analyze(samples)

        #expect(events.inputModeChanges.contains(.rhythmic))

        let rhythmPhrases = events.phrases.filter(\.isRhythmOnly)
        #expect(rhythmPhrases.count == 1)
        if let phrase = rhythmPhrases.first {
            // 8 strums; allow the DSP a ±2 margin at the edges (first-attack arming,
            // final-decay close) but never so loose the count is meaningless.
            #expect((6...9).contains(phrase.notes.count))
            #expect(phrase.notes.allSatisfy { $0.midiNote == 0 })
            #expect(phrase.duration > 2.0)
        }
    }

    @Test func hummedMelodyStaysMelodic() {
        var samples = TestSignals.melody([(60, 0.5), (64, 0.5), (67, 0.6)])
        samples.append(contentsOf: TestSignals.silence(duration: 0.6))
        let events = TestSignals.analyze(samples)

        #expect(events.inputModeChanges.isEmpty)
        let completed = events.phrases
        #expect(!completed.isEmpty)
        #expect(completed.allSatisfy { !$0.isRhythmOnly })
    }

    @Test func humThenStrumSwitchesModesAndKeepsBothPhrases() {
        var samples = TestSignals.melody([(60, 0.5), (64, 0.6)])
        samples.append(contentsOf: TestSignals.silence(duration: 0.5))
        samples.append(contentsOf: TestSignals.strummedChord(midiNotes: eMajor, strums: 6))
        samples.append(contentsOf: TestSignals.silence(duration: 0.6))
        let events = TestSignals.analyze(samples)

        let completed = events.phrases
        #expect(completed.contains { !$0.isRhythmOnly })
        #expect(completed.contains { $0.isRhythmOnly })
        #expect(events.inputModeChanges.contains(.rhythmic))

        // The melodic phrase must complete before the mode flips to rhythmic.
        let firstMelodicIndex = events.firstIndex {
            if case .phraseCompleted(let p) = $0, !p.isRhythmOnly { return true } else { return false }
        }
        let rhythmicSwitchIndex = events.firstIndex {
            if case .inputModeChanged(.rhythmic) = $0 { return true } else { return false }
        }
        if let melodic = firstMelodicIndex, let switched = rhythmicSwitchIndex {
            #expect(melodic < switched)
        }
    }

    @Test func rhythmPhraseInProgressDrivesTheLiveMeter() {
        // The live syllable meter must keep ticking while strumming: progress events
        // with a growing provisional note count.
        var samples = TestSignals.strummedChord(midiNotes: eMajor, strums: 6)
        samples.append(contentsOf: TestSignals.silence(duration: 0.6))
        let events = TestSignals.analyze(samples)

        let counts = events.compactMap {
            if case .phraseInProgress(_, let n) = $0 { n } else { nil }
        }
        #expect(counts.contains { $0 >= 3 })
    }
}

/// Deterministic unit coverage of the rhythm segmenter's boundary rules, driven by
/// synthetic hop sequences (10 ms per hop, matching the chain).
@Suite struct RhythmSegmenterTests {
    private func run(
        _ segmenter: RhythmSegmenter,
        from start: TimeInterval,
        for duration: TimeInterval,
        rms: Float,
        onsetAtFirstHop: Bool = false
    ) -> [RhythmSegmenter.Event] {
        var events: [RhythmSegmenter.Event] = []
        var t = start
        var first = true
        while t < start + duration {
            if let e = segmenter.ingest(time: t, rms: rms, energyOnset: first && onsetAtFirstHop) {
                events.append(e)
            }
            first = false
            t += 0.01
        }
        return events
    }

    @Test func steadyStrumsFormAPhraseAtTheSilenceBoundary() {
        let segmenter = RhythmSegmenter()
        var events: [RhythmSegmenter.Event] = []
        for i in 0..<4 {
            events += run(segmenter, from: Double(i) * 0.5, for: 0.5, rms: 0.4, onsetAtFirstHop: true)
        }
        events += run(segmenter, from: 2.0, for: 0.5, rms: 0.0)

        let phrases = events.compactMap { if case .completed(let p) = $0 { p } else { nil } }
        #expect(phrases.count == 1)
        if let phrase = phrases.first {
            #expect(phrase.notes.count == 4)
            #expect(phrase.isRhythmOnly)
            #expect(phrase.notes.allSatisfy { $0.midiNote == 0 })
        }
    }

    @Test func aSingleBumpIsDiscardedAsNoise() {
        let segmenter = RhythmSegmenter()
        var events = run(segmenter, from: 0, for: 0.3, rms: 0.4, onsetAtFirstHop: true)
        events += run(segmenter, from: 0.3, for: 0.6, rms: 0.0)
        let phrases = events.compactMap { if case .completed(let p) = $0 { p } else { nil } }
        #expect(phrases.isEmpty)
    }

    @Test func flushClosesTheOpenPhraseForModeHandoff() {
        let segmenter = RhythmSegmenter()
        for i in 0..<3 {
            _ = run(segmenter, from: Double(i) * 0.5, for: 0.5, rms: 0.4, onsetAtFirstHop: true)
        }
        let flushed = segmenter.flush(at: 1.5)
        guard case .completed(let phrase)? = flushed else {
            Issue.record("expected a completed phrase from flush")
            return
        }
        #expect(phrase.notes.count == 3)
        #expect(phrase.isRhythmOnly)
    }
}
