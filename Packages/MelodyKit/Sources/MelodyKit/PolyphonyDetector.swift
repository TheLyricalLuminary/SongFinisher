import Foundation
import Domain

/// Decides whether the incoming signal is a single melodic line (hum, voice, picked
/// notes) or polyphonic (strummed chords), driving the chain's melodic/rhythmic mode.
///
/// ## Why ratio math alone can't do this
/// A note with a missing fundamental and a root+fifth chord are spectrally the same
/// family: both are subsets of some virtual root's harmonic series (an E-major strum is
/// harmonics 2·3·4·5·6·8 of an inaudible E1). What separates them is *periodicity in
/// the time domain*: YIN locks confidently onto a missing-fundamental note's true
/// period, but a strummed chord's incommensurate string phases give no single period.
/// So the frame rule fuses both domains:
/// - **YIN confident** → the frame is polyphonic only if ≥ 2 strong spectral peaks are
///   inharmonic against *YIN's own f0* (the fifth and third of a chord fail this;
///   every partial of a genuine note passes).
/// - **YIN collapsed while the signal is energetic** (the classic strum attack) →
///   polyphonic if the spectrum still shows several strong peaks.
///
/// Frame votes are smoothed over ~0.5 s of energetic signal with enter/exit hysteresis
/// so mode never flaps mid-phrase. Silence doesn't vote: a decaying chord tail or a
/// breath between hummed phrases must not drag the mode around.
///
/// Not Sendable by design: confined to the analysis task/thread.
final class PolyphonyDetector {
    static let sampleRateDefault = 16_000.0
    static let fftSize = 1024
    /// Peak search range: covers guitar low E (82 Hz, with margin) up through the
    /// partials that distinguish chord tones.
    static let searchLowHz = 70.0
    static let searchHighHz = 1500.0
    /// A spectral peak is "strong" at ≥ this fraction of the frame's strongest peak.
    static let strongPeakRatio: Float = 0.12
    /// A peak is harmonic when within max(6% of root, 0.75 bin) of an integer multiple.
    static let harmonicRelativeTolerance = 0.06
    static let harmonicBinTolerance = 0.75
    /// YIN confidence at or above this counts as a confident single-F0 lock.
    static let confidentVoicingThreshold: Float = 0.5
    /// ≥ this many inharmonic strong peaks → polyphonic frame.
    static let inharmonicPeakThreshold = 2
    /// YIN-collapsed frames need this many strong peaks to vote polyphonic.
    static let collapsedPeakThreshold = 4
    /// Voting window (energetic frames only): 50 frames ≈ 0.5 s of sounding signal.
    static let voteWindow = 50
    static let minimumVotes = 25
    /// Enter rhythmic at ≥ 50% polyphonic votes; return to melodic at ≤ 15%.
    static let enterRhythmicFraction = 0.5
    static let exitRhythmicFraction = 0.15

    private let binWidth: Double
    private var votes: [Bool] = []
    private var noiseFloor = NoiseFloorTracker()
    private(set) var mode: InputMode = .melodic

    init(sampleRate: Double = PolyphonyDetector.sampleRateDefault) {
        self.binWidth = sampleRate / Double(Self.fftSize)
    }

    /// Feed one hop's magnitude spectrum (from the onset detector's FFT — never
    /// recomputed) plus the same hop's pitch frame. Returns the new mode when it flips.
    func ingest(magnitudes: [Float], frame: PitchFrame) -> InputMode? {
        let floor = noiseFloor.update(rms: frame.rmsEnergy)
        let energetic = frame.rmsEnergy > floor * 4
        guard energetic else { return nil }

        votes.append(classifyFrame(magnitudes: magnitudes, frame: frame))
        if votes.count > Self.voteWindow { votes.removeFirst() }
        guard votes.count >= Self.minimumVotes else { return nil }

        let fraction = Double(votes.lazy.filter { $0 }.count) / Double(votes.count)
        switch mode {
        case .melodic where fraction >= Self.enterRhythmicFraction:
            mode = .rhythmic
            return mode
        case .rhythmic where fraction <= Self.exitRhythmicFraction:
            mode = .melodic
            return mode
        default:
            return nil
        }
    }

    func reset() {
        votes.removeAll()
        noiseFloor = NoiseFloorTracker()
        mode = .melodic
    }

    /// One energetic frame's verdict. Internal for direct unit testing.
    func classifyFrame(magnitudes: [Float], frame: PitchFrame) -> Bool {
        let peaks = strongPeaks(in: magnitudes)
        guard peaks.count >= 3 else { return false }  // a chord shows ≥3 strong partials

        if let f0 = frame.frequencyHz, frame.confidence >= Self.confidentVoicingThreshold {
            return inharmonicCount(peaks: peaks, root: f0) >= Self.inharmonicPeakThreshold
        }

        // YIN collapse under strong signal: the strum-attack signature. A noisy but
        // genuinely monophonic frame (breath, consonant) rarely sustains ≥4 strong
        // stable peaks; a rung chord always does.
        if !frame.isVoiced, peaks.count >= Self.collapsedPeakThreshold {
            return true
        }

        // Low-confidence voiced frame: trust the spectral test against YIN's rough f0.
        if let f0 = frame.frequencyHz {
            return inharmonicCount(peaks: peaks, root: f0) >= Self.inharmonicPeakThreshold
        }
        return false
    }

    /// Local maxima ≥ `strongPeakRatio` × the strongest peak inside the search band,
    /// with parabolic bin refinement (±half-bin accuracy is not enough at 82 Hz).
    func strongPeaks(in magnitudes: [Float]) -> [Double] {
        let low = max(1, Int(Self.searchLowHz / binWidth))
        let high = min(magnitudes.count - 2, Int(Self.searchHighHz / binWidth))
        guard high > low else { return [] }

        var maxMagnitude: Float = 0
        for k in low...high { maxMagnitude = max(maxMagnitude, magnitudes[k]) }
        guard maxMagnitude > 1e-6 else { return [] }
        let threshold = maxMagnitude * Self.strongPeakRatio

        var peaks: [Double] = []
        for k in low...high {
            guard magnitudes[k] >= threshold,
                  magnitudes[k] > magnitudes[k - 1],
                  magnitudes[k] >= magnitudes[k + 1] else { continue }
            let y0 = Double(magnitudes[k - 1]), y1 = Double(magnitudes[k]), y2 = Double(magnitudes[k + 1])
            let denominator = y0 - 2 * y1 + y2
            var delta = 0.0
            if abs(denominator) > 1e-12 {
                delta = max(-0.5, min(0.5, 0.5 * (y0 - y2) / denominator))
            }
            peaks.append((Double(k) + delta) * binWidth)
        }
        return peaks
    }

    /// Peaks not within tolerance of any integer multiple of `root`.
    func inharmonicCount(peaks: [Double], root: Double) -> Int {
        guard root > 0 else { return 0 }
        let tolerance = max(root * Self.harmonicRelativeTolerance, binWidth * Self.harmonicBinTolerance)
        return peaks.lazy.filter { f in
            let multiple = (f / root).rounded()
            guard multiple >= 1 else { return true }
            return abs(f - multiple * root) > tolerance
        }.count
    }
}
