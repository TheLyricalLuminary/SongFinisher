import Foundation
import Accelerate

/// Half-wave-rectified spectral-flux onset detection (docs/ARCHITECTURE.md §8):
/// 1024-point FFT (Hann window, 10 ms hop), flux summed over ~100 Hz–5 kHz, adaptive
/// median+MAD threshold, peak-picked. Pitch-jump onsets for legato are fused downstream
/// in `NoteSegmenter`, which owns the running note pitch.
///
/// ## Valley-armed firing
/// An energy onset means *re-articulation*, and a re-articulation always carves an
/// energy valley: RMS dips (gap, consonant, breath) and rises again into the new attack.
/// The detector is therefore **armed only by a valley** (RMS < 78% of the running peak
/// for ≥2 frames) and fires **at most one onset per valley**, at a peak-picked flux
/// maximum above the adaptive threshold, provided RMS has risen off the valley floor.
/// Each condition maps to one physical phenomenon this must reject:
/// - one-per-valley  → vibrato/modulation flux bumps after an attack (no new valley);
/// - rise-off-floor  → spectral-leakage bursts when a tone truncates out of the window
///                     (flux peaks while RMS is still falling toward the valley);
/// - peak-picking    → the attack's own flux plateau re-firing on its falling tail;
/// - adaptive threshold → steady-state flux noise.
/// Pitch changes with no valley (true legato) are deliberately NOT energy onsets —
/// they belong to the NoteSegmenter's pitch-jump/melisma path.
///
/// Not Sendable by design: confined to the analysis task/thread.
final class SpectralFluxOnsetDetector {
    static let fftSize = 1024
    /// Safety floor between fires; the valley requirement is the real limiter.
    static let deadTimeFrames = 5
    static let thresholdWindowFrames = 70  // ±350 ms of flux history
    static let madMultiplier: Float = 1.5
    static let coldStartFluxFloor: Float = 0.05
    /// A 30 ms articulation gap seen through the 64 ms window dips RMS to ~73% of the
    /// tone level; 85% arms on it with real margin (hop-grid alignment shifts the
    /// measured dip a few percent per boundary). Sung-vibrato amplitude modulation can
    /// occasionally cross this too — harmless, because arming alone doesn't fire: the
    /// flux peak must also clear the adaptive threshold, which vibrato's own steady
    /// flux keeps elevated.
    static let valleyRatio: Float = 0.85
    static let valleyPersistFrames = 2
    /// RMS at fire time must have risen off the valley floor by this factor. Kept low:
    /// its only job is rejecting truncation bursts, which peak while RMS still sits AT
    /// the valley floor — any genuine rise clears 5% easily.
    static let riseOffValleyFactor: Float = 1.05

    private let dft: vDSP_DFT_Setup
    private let binLow: Int
    private let binHigh: Int
    private var hannWindow: [Float]
    private var previousMagnitudes: [Float]
    private var fluxHistory: [Float] = []
    private var framesSinceOnset = Int.max
    private var previousFlux: Float = 0
    private var beforePreviousFlux: Float = 0

    // Valley-arming state.
    private var armed = true                  // stream start counts as a valley
    private var valleyMinRMS: Float = 0.0002
    private var valleyCandidateFrames = 0
    private var runningPeakRMS: Float = 0

    /// The most recent frame's onset strength (fed to the tempo estimator every frame).
    private(set) var latestFlux: Float = 0

    /// The most recent frame's magnitude spectrum (fed to the polyphony detector every
    /// frame — computed once here, never recomputed downstream).
    private(set) var latestMagnitudes: [Float] = []

    init(sampleRate: Double = 16_000) {
        guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(Self.fftSize), .FORWARD) else {
            fatalError("vDSP_DFT_zrop_CreateSetup failed for size \(Self.fftSize)")
        }
        self.dft = setup
        let binWidth = sampleRate / Double(Self.fftSize)
        self.binLow = max(1, Int(100.0 / binWidth))
        self.binHigh = min(Self.fftSize / 2 - 1, Int(5000.0 / binWidth))
        self.hannWindow = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        self.previousMagnitudes = [Float](repeating: 0, count: Self.fftSize / 2)
    }

    deinit {
        vDSP_DFT_DestroySetup(dft)
    }

    /// Processes one window; returns true when an onset is confirmed.
    func process(window: [Float]) -> Bool {
        precondition(window.count >= Self.fftSize)
        let magnitudes = magnitudeSpectrum(window)

        var flux: Float = 0
        for k in binLow...binHigh {
            let delta = log1p(magnitudes[k]) - log1p(previousMagnitudes[k])
            if delta > 0 { flux += delta }
        }
        previousMagnitudes = magnitudes
        latestMagnitudes = magnitudes
        latestFlux = flux

        fluxHistory.append(flux)
        if fluxHistory.count > Self.thresholdWindowFrames { fluxHistory.removeFirst() }
        framesSinceOnset = framesSinceOnset == Int.max ? Int.max : framesSinceOnset + 1

        var windowRMS: Float = 0
        for i in 0..<Self.fftSize { windowRMS += window[i] * window[i] }
        windowRMS = (windowRMS / Float(Self.fftSize)).squareRoot()
        updateValleyState(rms: windowRMS)

        let threshold: Float
        if fluxHistory.count >= 10 {
            let sorted = fluxHistory.sorted()
            let median = sorted[sorted.count / 2]
            let deviations = fluxHistory.map { abs($0 - median) }.sorted()
            let mad = deviations[deviations.count / 2]
            threshold = median + Self.madMultiplier * max(mad, 0.01)
        } else {
            threshold = Self.coldStartFluxFloor
        }

        var fired = false
        let deadTimeClear = framesSinceOnset >= Self.deadTimeFrames || framesSinceOnset == Int.max
        if armed,
           deadTimeClear,
           previousFlux > threshold,
           previousFlux > beforePreviousFlux,
           previousFlux >= flux,
           windowRMS > valleyMinRMS * Self.riseOffValleyFactor + 0.0001 {
            fired = true
            framesSinceOnset = 0
            armed = false
            valleyCandidateFrames = 0
            runningPeakRMS = windowRMS
        }

        beforePreviousFlux = previousFlux
        previousFlux = flux
        return fired
    }

    func reset() {
        previousMagnitudes = [Float](repeating: 0, count: Self.fftSize / 2)
        latestMagnitudes.removeAll()
        fluxHistory.removeAll()
        framesSinceOnset = Int.max
        latestFlux = 0
        previousFlux = 0
        beforePreviousFlux = 0
        armed = true
        valleyMinRMS = 0.0002
        valleyCandidateFrames = 0
        runningPeakRMS = 0
    }

    /// Arms the detector when RMS dips below `valleyRatio` × the running peak for at
    /// least `valleyPersistFrames`; tracks the valley floor while armed.
    private func updateValleyState(rms: Float) {
        runningPeakRMS = max(rms, runningPeakRMS * 0.999)

        if armed {
            valleyMinRMS = min(valleyMinRMS, rms)
            return
        }

        if rms < runningPeakRMS * Self.valleyRatio {
            valleyCandidateFrames += 1
            if valleyCandidateFrames >= Self.valleyPersistFrames {
                armed = true
                valleyMinRMS = rms
            }
        } else {
            valleyCandidateFrames = 0
        }
    }

    /// Hann-windowed magnitude spectrum via vDSP's real-input DFT (zrop packing).
    private func magnitudeSpectrum(_ window: [Float]) -> [Float] {
        let n = Self.fftSize
        let half = n / 2

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(window, 1, hannWindow, 1, &windowed, 1, vDSP_Length(n))

        // zrop packing: even samples → real input, odd samples → imaginary input.
        var inReal = [Float](repeating: 0, count: half)
        var inImag = [Float](repeating: 0, count: half)
        for i in 0..<half {
            inReal[i] = windowed[2 * i]
            inImag[i] = windowed[2 * i + 1]
        }

        var outReal = [Float](repeating: 0, count: half)
        var outImag = [Float](repeating: 0, count: half)
        vDSP_DFT_Execute(dft, inReal, inImag, &outReal, &outImag)

        var magnitudes = [Float](repeating: 0, count: half)
        outReal.withUnsafeMutableBufferPointer { realPtr in
            outImag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }
        return magnitudes
    }
}
