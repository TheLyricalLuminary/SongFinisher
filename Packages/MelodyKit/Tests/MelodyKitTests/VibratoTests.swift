import Testing
import Foundation
import Domain
@testable import MelodyKit

/// Phase 4 Task 0 acceptance: vibrato in the healthy trained range (4.5–6.5 Hz,
/// extents up to and beyond ±50 cents) must NOT split a sustained note, while genuine
/// pitch changes — with or without vibrato riding on them — must still split.
@Suite struct VibratoTests {

    /// Two vibrato notes separated by a breath. Each must survive as exactly one note.
    @Test("vibrato notes are not shredded into fragments", arguments: [
        (rate: 4.5, extent: 30.0),
        (rate: 5.4, extent: 40.0),   // male norm (Nix et al. 2016)
        (rate: 5.9, extent: 50.0),   // female norm
        (rate: 6.5, extent: 50.0),
        (rate: 5.5, extent: 70.0),   // expressive extent beyond the 60-cent threshold
    ])
    func vibratoDoesNotSplitNotes(rate: Double, extent: Double) {
        var samples = TestSignals.vibratoTone(midi: 60, duration: 0.6, rateHz: rate, extentCents: extent)
        samples.append(contentsOf: TestSignals.silence(duration: 0.08))
        samples.append(contentsOf: TestSignals.vibratoTone(midi: 64, duration: 0.7, rateHz: rate, extentCents: extent))
        samples.append(contentsOf: TestSignals.silence(duration: 0.6))

        let phrases = TestSignals.analyze(samples).phrases
        guard let phrase = phrases.first, phrases.count == 1 else {
            Issue.record("expected 1 phrase, got \(phrases.count)")
            return
        }
        #expect(phrase.notes.count == 2, "rate \(rate) Hz, ±\(extent)c produced \(phrase.notes.count) notes")
    }

    /// A single long vibrato note held for 2 s — the sustained expressive note users
    /// care most about — plus a companion note so the phrase clears its minimums.
    @Test func longSustainedVibratoNoteStaysWhole() {
        var samples = TestSignals.tone(frequency: TestSignals.frequency(midi: 62), duration: 0.3)
        samples.append(contentsOf: TestSignals.silence(duration: 0.08))
        samples.append(contentsOf: TestSignals.vibratoTone(midi: 67, duration: 2.0, rateHz: 5.5, extentCents: 45))
        samples.append(contentsOf: TestSignals.silence(duration: 0.6))

        let phrases = TestSignals.analyze(samples).phrases
        guard let phrase = phrases.first else {
            Issue.record("no phrase detected")
            return
        }
        #expect(phrase.notes.count == 2)
        if phrase.notes.count == 2 {
            #expect(phrase.notes[1].duration > 1.5, "sustained note was truncated")
            #expect(abs(phrase.notes[1].midiNote - 67) < 0.5, "vibrato biased the note pitch")
        }
    }

    /// A genuine legato pitch change with vibrato riding on BOTH notes must still split:
    /// the decisive-jump override fires even while the oscillation flag is warm.
    @Test func realNoteChangeWithVibratoStillSplits() {
        let count1 = Int(0.7 * TestSignals.sampleRate)
        let count2 = Int(0.8 * TestSignals.sampleRate)
        var samples = [Float](repeating: 0, count: count1 + count2)
        var phase = 0.0
        for i in 0..<(count1 + count2) {
            let t = Double(i) / TestSignals.sampleRate
            let baseMidi = i < count1 ? 60.0 : 65.0   // C4 → F4, 5 semitones, no gap
            let cents = 40.0 * sin(2.0 * .pi * 5.5 * t)
            let f = TestSignals.frequency(midi: baseMidi) * pow(2.0, cents / 1200.0)
            phase += 2.0 * .pi * f / TestSignals.sampleRate
            samples[i] = 0.5 * Float(sin(phase))
        }
        samples.append(contentsOf: TestSignals.silence(duration: 0.6))

        let phrases = TestSignals.analyze(samples).phrases
        guard let phrase = phrases.first else {
            Issue.record("no phrase detected")
            return
        }
        #expect(phrase.notes.count == 2, "got \(phrase.notes.count) notes")
        if phrase.notes.count == 2 {
            #expect(abs(phrase.notes[0].midiNote - 60) < 0.6)
            #expect(abs(phrase.notes[1].midiNote - 65) < 0.6)
        }
    }

    /// Slow intonation drift within a long note (< 60 cents total) must not split it.
    @Test func slowPitchDriftDoesNotSplit() {
        let count = Int(1.5 * TestSignals.sampleRate)
        var samples = [Float](repeating: 0, count: count)
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / TestSignals.sampleRate
            let cents = 40.0 * (t / 1.5)   // drifts up 40 cents over the note
            let f = TestSignals.frequency(midi: 64) * pow(2.0, cents / 1200.0)
            phase += 2.0 * .pi * f / TestSignals.sampleRate
            samples[i] = 0.5 * Float(sin(phase))
        }
        var full = TestSignals.tone(frequency: TestSignals.frequency(midi: 60), duration: 0.3)
        full.append(contentsOf: TestSignals.silence(duration: 0.08))
        full.append(contentsOf: samples)
        full.append(contentsOf: TestSignals.silence(duration: 0.6))

        let phrases = TestSignals.analyze(full).phrases
        guard let phrase = phrases.first else {
            Issue.record("no phrase detected")
            return
        }
        #expect(phrase.notes.count == 2)
    }
}
