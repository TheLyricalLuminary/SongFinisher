import Foundation
import Domain

/// Tempo from autocorrelation of the onset-strength envelope (docs/ARCHITECTURE.md §8):
/// 8 s sliding window re-evaluated every 2 s, lag search 60–200 BPM, log-Gaussian prior
/// centered at 105 BPM, harmonic disambiguation, exponential smoothing.
///
/// Not Sendable by design: confined to the analysis task/thread.
final class TempoEstimator {
    static let framesPerSecond = 100.0
    static let windowFrames = 800          // 8 s
    static let evaluateEveryFrames = 200   // 2 s
    static let minBPM = 60.0
    static let maxBPM = 200.0
    static let priorCenterBPM = 105.0
    static let priorSigmaOctaves = 0.7

    private var envelope: [Float] = []
    private var framesSinceEvaluation = 0
    private var smoothedBPM: Double?
    private(set) var current: TempoEstimate?

    /// Feed one frame's onset strength; returns a new estimate when re-evaluated, else nil.
    func ingest(fluxValue: Float, time: TimeInterval) -> TempoEstimate? {
        envelope.append(fluxValue)
        if envelope.count > Self.windowFrames { envelope.removeFirst() }

        framesSinceEvaluation += 1
        guard framesSinceEvaluation >= Self.evaluateEveryFrames,
              envelope.count >= Self.windowFrames / 2 else { return nil }
        framesSinceEvaluation = 0

        guard let raw = estimateBPM() else { return nil }

        // Exponential smoothing so the displayed BPM doesn't flap.
        let bpm: Double
        if let previous = smoothedBPM {
            bpm = previous + (raw.bpm - previous) * 0.3
        } else {
            bpm = raw.bpm
        }
        smoothedBPM = bpm

        let estimate = TempoEstimate(bpm: bpm, confidence: raw.confidence, beatPhase: beatPhase(bpm: bpm, time: time))
        current = estimate
        return estimate
    }

    func reset() {
        envelope.removeAll()
        framesSinceEvaluation = 0
        smoothedBPM = nil
        current = nil
    }

    private func estimateBPM() -> (bpm: Double, confidence: Float)? {
        let n = envelope.count
        let mean = envelope.reduce(0, +) / Float(n)
        let centered = envelope.map { $0 - mean }

        let lagMin = Int(Self.framesPerSecond * 60.0 / Self.maxBPM)  // 30 frames @ 200 BPM
        let lagMax = Int(Self.framesPerSecond * 60.0 / Self.minBPM)  // 100 frames @ 60 BPM
        guard n > lagMax * 2 else { return nil }

        var best: (lag: Int, score: Double) = (0, 0)
        var totalScore = 0.0
        var scoreCount = 0

        for lag in lagMin...lagMax {
            var correlation: Float = 0
            for i in 0..<(n - lag) {
                correlation += centered[i] * centered[i + lag]
            }
            let bpm = Self.framesPerSecond * 60.0 / Double(lag)
            // Log-Gaussian prior over BPM resolves half/double-time ambiguity.
            let octaves = log2(bpm / Self.priorCenterBPM)
            let prior = exp(-0.5 * (octaves / Self.priorSigmaOctaves) * (octaves / Self.priorSigmaOctaves))
            // Reward lags whose double (half-tempo harmonic) is also correlated.
            var harmonic: Float = 0
            if lag * 2 <= lagMax {
                for i in 0..<(n - lag * 2) {
                    harmonic += centered[i] * centered[i + lag * 2]
                }
            }
            let score = (Double(correlation) + 0.3 * Double(max(0, harmonic))) * prior
            totalScore += max(0, score)
            scoreCount += 1
            if score > best.score { best = (lag, score) }
        }

        guard best.lag > 0, best.score > 0 else { return nil }
        let meanScore = totalScore / Double(max(1, scoreCount))
        let prominence = meanScore > 0 ? best.score / (meanScore * 4) : 0
        let confidence = Float(min(1, max(0, prominence)))
        let bpm = Self.framesPerSecond * 60.0 / Double(best.lag)
        return (bpm, confidence)
    }

    /// Best-aligned comb offset: the envelope-peak time nearest to `time`, folded to phase.
    private func beatPhase(bpm: Double, time: TimeInterval) -> TimeInterval {
        guard let maxIndex = envelope.indices.max(by: { envelope[$0] < envelope[$1] }) else { return 0 }
        let period = 60.0 / bpm
        let peakTime = time - Double(envelope.count - 1 - maxIndex) / Self.framesPerSecond
        return peakTime.truncatingRemainder(dividingBy: period)
    }
}
