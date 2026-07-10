import Foundation
import Domain

/// YIN pitch detection (de Cheveigné & Kawahara 2002) with the cumulative-mean-normalized
/// difference function, parameterized per docs/ARCHITECTURE.md §8:
/// window 1024 @ 16 kHz (64 ms), search 65–1047 Hz, absolute threshold 0.15, parabolic
/// interpolation, 5-frame median filter, voicing hysteresis + rolling noise-floor RMS gate.
///
/// The difference function is computed as plain-Swift O(W·τmax) — ~0.2 ms/frame on Apple
/// Silicon, well inside budget. The FFT-accelerated variant is a drop-in optimization.
///
/// Not Sendable by design: confined to the analysis task/thread.
final class YINPitchDetector {
    static let windowSize = 1024
    static let minFrequency = 65.0     // C2
    static let maxFrequency = 1047.0   // C6
    static let threshold: Float = 0.15
    static let unvoicedCMNDCutoff: Float = 0.35   // hysteresis exit
    static let voicedCMNDCutoff: Float = 0.20     // hysteresis enter

    private let sampleRate: Double
    private let tauMin: Int
    private let tauMax: Int
    private var cmnd: [Float]
    private var medianWindow: [Double?] = []      // last 5 raw f0 values (nil = unvoiced)
    private var isCurrentlyVoiced = false
    private var noiseFloorTracker = NoiseFloorTracker()

    init(sampleRate: Double = 16_000) {
        self.sampleRate = sampleRate
        self.tauMin = max(2, Int(sampleRate / Self.maxFrequency))
        self.tauMax = min(Self.windowSize / 2, Int(sampleRate / Self.minFrequency) + 1)
        self.cmnd = [Float](repeating: 0, count: tauMax + 1)
    }

    /// Analyzes one window of `windowSize` samples. Returns the pitch frame for `time`.
    func process(window: [Float], time: TimeInterval) -> PitchFrame {
        precondition(window.count >= Self.windowSize)

        let rms = Self.rms(window)
        let noiseFloor = noiseFloorTracker.update(rms: rms)

        let (bestTau, bestValue) = cmndMinimum(window)

        let clarity = 1.0 - bestValue
        let rmsGate = rms > noiseFloor * 4  // ~12 dB above the rolling floor

        // Hysteresis: entering voiced needs a clearly periodic frame; leaving needs a
        // clearly aperiodic one — avoids flapping on breathy sustains.
        let framePeriodic: Bool
        if isCurrentlyVoiced {
            framePeriodic = bestValue < Self.unvoicedCMNDCutoff
        } else {
            framePeriodic = bestValue < Self.voicedCMNDCutoff
        }
        let voiced = framePeriodic && rmsGate && bestTau > 0
        isCurrentlyVoiced = voiced

        var frequency: Double? = nil
        if voiced {
            let refinedTau = parabolicRefine(around: bestTau)
            frequency = sampleRate / refinedTau
        }

        let smoothed = medianFiltered(frequency)
        let midi = smoothed.map { 69.0 + 12.0 * log2($0 / 440.0) }

        return PitchFrame(
            time: time,
            frequencyHz: smoothed,
            midiNote: midi,
            rmsEnergy: rms,
            confidence: max(0, min(1, clarity))
        )
    }

    func reset() {
        medianWindow.removeAll()
        isCurrentlyVoiced = false
        noiseFloorTracker = NoiseFloorTracker()
    }

    // MARK: - CMND

    /// Difference function + cumulative mean normalization; returns (τ*, d'(τ*)).
    private func cmndMinimum(_ window: [Float]) -> (tau: Int, value: Float) {
        let w = Self.windowSize / 2

        cmnd[0] = 1
        var runningSum: Float = 0

        // d(τ) = Σ_{j=0}^{W/2} (x[j] - x[j+τ])²
        for tau in 1...tauMax {
            var d: Float = 0
            window.withUnsafeBufferPointer { p in
                for j in 0..<w {
                    let diff = p[j] - p[j + tau]
                    d += diff * diff
                }
            }
            runningSum += d
            cmnd[tau] = runningSum > 0 ? d * Float(tau) / runningSum : 1
        }

        // First local minimum whose *interpolated* depth clears the threshold wins.
        // Testing raw integer-lag values here causes octave-down errors: a pitch whose
        // period falls halfway between integer lags has a shallow sampled dip at τ but a
        // deep one at 2τ (nearly integer-aligned), so a raw-value scan skips the true
        // fundamental. Parabolic depth interpolation reveals the real dip.
        var bestTau = 0
        var bestValue: Float = 1
        var tau = tauMin
        while tau <= tauMax {
            let isLocalMin = cmnd[tau] <= cmnd[tau - 1] && (tau == tauMax || cmnd[tau] <= cmnd[tau + 1])
            if isLocalMin {
                let depth = interpolatedDipDepth(at: tau)
                if depth < Self.threshold {
                    return (tau, max(0, depth))
                }
                if depth < bestValue {
                    bestValue = max(0, depth)
                    bestTau = tau
                }
            }
            tau += 1
        }
        return (bestTau, bestValue)
    }

    /// Parabolic interpolation of the dip's minimum *value* (not its position).
    private func interpolatedDipDepth(at tau: Int) -> Float {
        guard tau > tauMin, tau < tauMax else { return cmnd[tau] }
        let y0 = cmnd[tau - 1], y1 = cmnd[tau], y2 = cmnd[tau + 1]
        let denominator = y0 - 2 * y1 + y2
        guard denominator > 1e-12 else { return y1 }
        let interpolated = y1 - (y0 - y2) * (y0 - y2) / (8 * denominator)
        return min(y1, max(0, interpolated))
    }

    /// Sub-sample lag refinement via parabolic interpolation of the CMND minimum.
    private func parabolicRefine(around tau: Int) -> Double {
        guard tau > tauMin, tau < tauMax else { return Double(tau) }
        let y0 = Double(cmnd[tau - 1]), y1 = Double(cmnd[tau]), y2 = Double(cmnd[tau + 1])
        let denominator = y0 - 2 * y1 + y2
        guard abs(denominator) > 1e-12 else { return Double(tau) }
        let delta = 0.5 * (y0 - y2) / denominator
        return Double(tau) + max(-1, min(1, delta))
    }

    // MARK: - Post-processing

    /// 5-frame median filter over f0 — kills octave-jump glitches at +2 frames of latency.
    /// Unvoiced frames pass through as nil and do not pollute the median.
    private func medianFiltered(_ f0: Double?) -> Double? {
        medianWindow.append(f0)
        if medianWindow.count > 5 { medianWindow.removeFirst() }
        guard f0 != nil else { return nil }
        let voiced = medianWindow.compactMap(\.self).sorted()
        guard !voiced.isEmpty else { return nil }
        return voiced[voiced.count / 2]
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// Rolling noise-floor estimate. Adapts downward instantly and upward only while the
/// frame is plausibly noise (within 6× the current floor). Frames far above the floor
/// are signal and must NOT drag it up — an unconditional upward drift eats sustained
/// notes (measured: a 2 s tone lost voicing at 1.78 s as the floor climbed into the
/// rms > 4×floor gate). A vestigial drift remains so a genuine noise-step (fan turns
/// on) eventually re-converges; its time constant (~minutes) is far beyond the 12 s
/// phrase cap, so no singable note can be gated out.
struct NoiseFloorTracker {
    private var floor: Float = 0.0005

    mutating func update(rms: Float) -> Float {
        if rms < floor {
            floor = rms                        // fast attack downward
        } else if rms < floor * 6 {
            floor += (rms - floor) * 0.02      // within the noise band: adapt normally
        } else {
            floor += (rms - floor) * 0.0001    // clear signal: vestigial drift only
        }
        return max(floor, 0.0002)              // never zero: silence must not gate open
    }
}
