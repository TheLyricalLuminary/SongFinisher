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

    /// A chord: simultaneous voices under a shared attack/release envelope, per-voice
    /// amplitude normalized so the sum never clips. Each voice carries three harmonic
    /// partials (1×, 2× at half, 3× at quarter amplitude) — a pluck-ish timbre. Pure
    /// sines would be an unrealistically hard case for spectral peak analysis: low
    /// guitar strings sit ~2.6 FFT bins apart and their windowed main lobes merge,
    /// which real string harmonics (spread far up the spectrum) never suffer from.
    static func chord(midiNotes: [Double], duration: TimeInterval, amplitude: Float = 0.5) -> [Float] {
        let count = Int(duration * sampleRate)
        let attack = min(count / 8, 160)
        let release = min(count / 8, 160)
        let partials: [(multiple: Double, level: Float)] = [(1, 1.0), (2, 0.5), (3, 0.25)]
        let perVoice = amplitude / (Float(max(1, midiNotes.count)) * 1.75)
        var out = [Float](repeating: 0, count: count)
        for midi in midiNotes {
            let f = frequency(midi: midi)
            for partial in partials {
                let pf = f * partial.multiple
                guard pf < sampleRate / 2 else { continue }
                for i in 0..<count {
                    let phase = 2.0 * Double.pi * pf * Double(i) / sampleRate
                    out[i] += perVoice * partial.level * Float(sin(phase))
                }
            }
        }
        for i in 0..<count {
            var env: Float = 1
            if i < attack { env = Float(i) / Float(max(1, attack)) }
            if i >= count - release { env = Float(count - i) / Float(max(1, release)) }
            out[i] *= env
        }
        return out
    }

    /// A strummed progression: the same chord re-articulated `strums` times with short
    /// articulation gaps, like steady down-strums on a guitar.
    static func strummedChord(
        midiNotes: [Double],
        strums: Int,
        strumDuration: TimeInterval = 0.45,
        gap: TimeInterval = 0.05
    ) -> [Float] {
        var out: [Float] = []
        for _ in 0..<strums {
            out.append(contentsOf: chord(midiNotes: midiNotes, duration: strumDuration))
            out.append(contentsOf: silence(duration: gap))
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
    var inputModeChanges: [InputMode] {
        compactMap { if case .inputModeChanged(let m) = $0 { m } else { nil } }
    }
}
