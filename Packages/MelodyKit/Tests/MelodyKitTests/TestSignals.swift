import Foundation
@testable import MelodyKit

/// Synthesized 16 kHz test signals with exact ground truth (docs/ARCHITECTURE.md §11:
/// "synthesized fixtures give exact ground truth").
enum TestSignals {
    static let sampleRate = 16_000.0

    /// A sine tone with a short attack/release envelope so onsets are detectable.
    static func tone(frequency: Double, duration: TimeInterval, amplitude: Float = 0.5) -> [Float] {
        let count = Int(duration * sampleRate)
        let attack = min(count / 8, 160)   // ≤10 ms attack
        let release = min(count / 8, 160)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let phase = 2.0 * Double.pi * frequency * Double(i) / sampleRate
            var env: Float = 1
            if i < attack { env = Float(i) / Float(max(1, attack)) }
            if i >= count - release { env = Float(count - i) / Float(max(1, release)) }
            out[i] = amplitude * env * Float(sin(phase))
        }
        return out
    }

    static func silence(duration: TimeInterval) -> [Float] {
        [Float](repeating: 0, count: Int(duration * sampleRate))
    }

    /// A melody of (midiNote, duration) tones separated by tiny articulation gaps.
    static func melody(_ notes: [(midi: Double, duration: TimeInterval)], gap: TimeInterval = 0.03) -> [Float] {
        var out: [Float] = []
        for note in notes {
            out.append(contentsOf: tone(frequency: frequency(midi: note.midi), duration: note.duration))
            out.append(contentsOf: silence(duration: gap))
        }
        return out
    }

    static func frequency(midi: Double) -> Double {
        440.0 * pow(2.0, (midi - 69.0) / 12.0)
    }

    /// A chord: simultaneous pure tones summed sample-by-sample. Deliberately pure sine
    /// (no harmonics) so the chroma detector sees only the exact chord tones — no
    /// overtone-series contamination to muddy the ground truth (docs/ARCHITECTURE.md §11).
    /// A lower per-note amplitude than `tone()`'s default keeps the summed peak well under
    /// clipping even for 4-note chords.
    static func chord(midiNotes: [Double], duration: TimeInterval, amplitude: Float = 0.2) -> [Float] {
        let count = Int(duration * sampleRate)
        var out = [Float](repeating: 0, count: count)
        for midi in midiNotes {
            let tone = tone(frequency: frequency(midi: midi), duration: duration, amplitude: amplitude)
            for i in 0..<min(count, tone.count) {
                out[i] += tone[i]
            }
        }
        return out
    }

    /// A tone with sinusoidal vibrato: rate in Hz, extent in cents (± around center).
    /// Phase-continuous so the vibrato itself introduces no spectral-flux attacks.
    static func vibratoTone(
        midi: Double,
        duration: TimeInterval,
        rateHz: Double,
        extentCents: Double,
        amplitude: Float = 0.5
    ) -> [Float] {
        let count = Int(duration * sampleRate)
        let center = frequency(midi: midi)
        let attack = min(count / 8, 160)
        let release = min(count / 8, 160)
        var out = [Float](repeating: 0, count: count)
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let cents = extentCents * sin(2.0 * .pi * rateHz * t)
            let f = center * pow(2.0, cents / 1200.0)
            phase += 2.0 * .pi * f / sampleRate
            var env: Float = 1
            if i < attack { env = Float(i) / Float(max(1, attack)) }
            if i >= count - release { env = Float(count - i) / Float(max(1, release)) }
            out[i] = amplitude * env * Float(sin(phase))
        }
        return out
    }

    /// Runs samples through a fresh AnalysisChain and collects all events.
    static func analyze(_ samples: [Float]) -> [Domain.AnalysisEvent] {
        let chain = AnalysisChain()
        var events: [Domain.AnalysisEvent] = []
        chain.process(samples: samples) { events.append($0) }
        chain.flush { events.append($0) }
        return events
    }
}

import Domain

extension Array where Element == AnalysisEvent {
    var phrases: [Phrase] {
        compactMap { if case .phraseCompleted(let p) = $0 { p } else { nil } }
    }
    var pitchFrames: [PitchFrame] {
        compactMap { if case .pitch(let f) = $0 { f } else { nil } }
    }
    var tempoUpdates: [TempoEstimate] {
        compactMap { if case .tempoUpdated(let t) = $0 { t } else { nil } }
    }
    var chordUpdates: [ChordEstimate] {
        compactMap { if case .chordUpdated(let c) = $0 { c } else { nil } }
    }
}
