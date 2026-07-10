import Foundation
import Accelerate

/// Half-wave-rectified spectral-flux onset detection (docs/ARCHITECTURE.md §8):
/// 1024-point FFT (Hann window, 10 ms hop), flux summed over ~100 Hz–5 kHz, adaptive
/// median+MAD threshold, 50 ms dead time. Pitch-jump onsets for legato are fused
/// downstream in `NoteSegmenter`, which owns the running note pitch.
///
/// Not Sendable by design: confined to the analysis task/thread.
final class SpectralFluxOnsetDetector {
    static let fftSize = 1024
    static let deadTimeFrames = 5          // 50 ms @ 100 fps
    static let thresholdWindowFrames = 70  // ±350 ms of flux history
    static let madMultiplier: Float = 1.5
    static let coldStartFluxFloor: Float = 0.05

    /// A flux peak only counts as an onset if RMS at the peak has *risen* by this factor
    /// over the quietest of the few frames before it. Attacks rise out of a dip; a tone
    /// truncating out of the window bursts flux while RMS falls; a pitch glide bursts
    /// flux while RMS stays flat. Flux magnitude alone cannot separate these (measured:
    /// glide ≈ 5, attack ≈ 6–38) — the RMS shape can.
    static let rmsRiseFactor: Float = 1.15
    static let rmsLookbackFrames = 4

    private let dft: vDSP_DFT_Setup
    private let binLow: Int
    private let binHigh: Int
    private var hannWindow: [Float]
    private var previousMagnitudes: [Float]
    private var fluxHistory: [Float] = []
    private var rmsHistory: [Float] = []
    private var framesSinceOnset = Int.max
    private var previousFlux: Float = 0
    private var beforePreviousFlux: Float = 0

    /// The most recent frame's onset strength (fed to the tempo estimator every frame).
    private(set) var latestFlux: Float = 0

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

    /// Processes one window; returns true when an onset is confirmed. Onsets are
    /// peak-picked: a frame fires only when the *previous* frame's flux was a local
    /// maximum above the adaptive threshold — thresholding alone re-fires on the
    /// falling tail of an attack the moment the dead time expires.
    func process(window: [Float]) -> Bool {
        precondition(window.count >= Self.fftSize)
        let magnitudes = magnitudeSpectrum(window)

        var flux: Float = 0
        for k in binLow...binHigh {
            let delta = log1p(magnitudes[k]) - log1p(previousMagnitudes[k])
            if delta > 0 { flux += delta }
        }
        previousMagnitudes = magnitudes
        latestFlux = flux

        fluxHistory.append(flux)
        if fluxHistory.count > Self.thresholdWindowFrames { fluxHistory.removeFirst() }
        framesSinceOnset = framesSinceOnset == Int.max ? Int.max : framesSinceOnset + 1

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

        var windowRMS: Float = 0
        for i in 0..<Self.fftSize { windowRMS += window[i] * window[i] }
        windowRMS = (windowRMS / Float(Self.fftSize)).squareRoot()
        rmsHistory.append(windowRMS)
        if rmsHistory.count > Self.rmsLookbackFrames + 2 { rmsHistory.removeFirst() }

        var fired = false
        let deadTimeClear = framesSinceOnset >= Self.deadTimeFrames || framesSinceOnset == Int.max
        if deadTimeClear,
           previousFlux > threshold,
           previousFlux > beforePreviousFlux,
           previousFlux >= flux,
           rmsRoseIntoPeak() {
            fired = true
            framesSinceOnset = 0
        }

        beforePreviousFlux = previousFlux
        previousFlux = flux
        return fired
    }

    /// RMS at the flux peak (one frame back) must exceed `rmsRiseFactor` × the quietest
    /// RMS in the few frames before it.
    private func rmsRoseIntoPeak() -> Bool {
        guard rmsHistory.count >= 2 else { return true }  // first frames: nothing to rise from
        let peakRMS = rmsHistory[rmsHistory.count - 2]
        let lookback = rmsHistory.prefix(max(0, rmsHistory.count - 2))
        guard let quietest = lookback.min() else { return true }
        return peakRMS > quietest * Self.rmsRiseFactor + 0.0001
    }

    func reset() {
        previousMagnitudes = [Float](repeating: 0, count: Self.fftSize / 2)
        fluxHistory.removeAll()
        rmsHistory.removeAll()
        framesSinceOnset = Int.max
        latestFlux = 0
        previousFlux = 0
        beforePreviousFlux = 0
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
