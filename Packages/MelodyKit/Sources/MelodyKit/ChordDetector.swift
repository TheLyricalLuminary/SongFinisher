import Foundation
import Accelerate
import Domain

/// Chroma-based chord detection: a 4096-sample FFT (Hann window) folds spectral energy
/// into a 12-bin pitch-class histogram ("chromagram"), re-evaluated every ~200 ms — much
/// slower than the 10 ms pitch/onset cadence, because harmonic content (unlike a single
/// melodic pitch) needs a wider analysis window to resolve low-register chord tones and
/// doesn't change fast enough to need per-hop updates. The chroma vector is matched by
/// cosine similarity against 60 templates (12 roots × 5 qualities from `ChordQuality`).
///
/// This is intentionally a simplification, not full MIR-grade harmony transcription: real
/// instrument timbre spreads energy across harmonics of each played note, which can pull
/// the match toward "major" (the overtone series itself outlines a major triad). Good
/// enough to give lyric generation a coarse major/minor/tension read, same spirit as
/// `TempoEstimator`'s tempo-not-perfect-beat-tracking tradeoff.
///
/// Not Sendable by design: confined to the analysis task/thread.
final class ChordDetector {
    static let fftSize = 4096
    /// 20 hops × 10 ms = ~200 ms between re-evaluations (docs/ARCHITECTURE.md §8 companion).
    static let evaluateEveryHops = 20
    static let minFrequencyHz = 100.0
    static let maxFrequencyHz = 2000.0
    /// Below this summed chroma energy the window is effectively silence/noise — no chord.
    static let minChromaEnergy: Float = 0.02

    private let dft: vDSP_DFT_Setup
    private var hannWindow: [Float]
    /// Precomputed per-bin pitch class (0–11), or -1 for bins outside the analysis band.
    private let binPitchClass: [Int]
    private let templates: [(root: Int, quality: ChordQuality, vector: [Float])]

    private var buffer: [Float] = []
    private var hopsSinceEvaluation = 0
    private(set) var current: ChordEstimate?

    init(sampleRate: Double = 16_000) {
        guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(Self.fftSize), .FORWARD) else {
            fatalError("vDSP_DFT_zrop_CreateSetup failed for size \(Self.fftSize)")
        }
        self.dft = setup
        self.hannWindow = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))

        let half = Self.fftSize / 2
        var classes = [Int](repeating: -1, count: half)
        for k in 1..<half {
            let freq = Double(k) * sampleRate / Double(Self.fftSize)
            guard freq >= Self.minFrequencyHz, freq <= Self.maxFrequencyHz else { continue }
            let midi = 69.0 + 12.0 * log2(freq / 440.0)
            classes[k] = ((Int(midi.rounded()) % 12) + 12) % 12
        }
        self.binPitchClass = classes
        self.templates = Self.buildTemplates()
    }

    deinit {
        vDSP_DFT_DestroySetup(dft)
    }

    /// Feed one hop's worth of new samples (not the whole sliding window — the chroma
    /// buffer keeps its own longer history so callers don't double-count overlap).
    /// Returns a new estimate when re-evaluated, else nil.
    func ingest(hopSamples: [Float]) -> ChordEstimate? {
        buffer.append(contentsOf: hopSamples)
        if buffer.count > Self.fftSize {
            buffer.removeFirst(buffer.count - Self.fftSize)
        }

        hopsSinceEvaluation += 1
        guard hopsSinceEvaluation >= Self.evaluateEveryHops, buffer.count >= Self.fftSize else { return nil }
        hopsSinceEvaluation = 0

        let chroma = chromagram(from: buffer)
        let energy = chroma.reduce(0, +)
        guard energy > Self.minChromaEnergy else {
            current = nil
            return nil
        }

        let norm = sqrt(chroma.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        let normalizedChroma = chroma.map { $0 / norm }

        var best: (root: Int, quality: ChordQuality, score: Float) = (0, .major, -1)
        for template in templates {
            var dot: Float = 0
            for i in 0..<12 { dot += normalizedChroma[i] * template.vector[i] }
            if dot > best.score {
                best = (template.root, template.quality, dot)
            }
        }

        let confidence = Float(min(1, max(0, best.score)))
        let estimate = ChordEstimate(root: best.root, quality: best.quality, confidence: confidence)
        current = estimate
        return estimate
    }

    func reset() {
        buffer.removeAll()
        hopsSinceEvaluation = 0
        current = nil
    }

    /// Weighted interval templates: root strongest, then descending by interval order —
    /// mirrors how strongly each chord tone typically registers relative to the root.
    private static func buildTemplates() -> [(root: Int, quality: ChordQuality, vector: [Float])] {
        let intervalWeights: [Float] = [1.0, 0.8, 0.6, 0.5]
        var result: [(root: Int, quality: ChordQuality, vector: [Float])] = []
        for quality in ChordQuality.allCases {
            for root in 0..<12 {
                var vector = [Float](repeating: 0, count: 12)
                for (i, interval) in quality.intervals.enumerated() {
                    let pc = (root + interval) % 12
                    vector[pc] = intervalWeights[min(i, intervalWeights.count - 1)]
                }
                let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
                if norm > 0 {
                    for i in 0..<12 { vector[i] /= norm }
                }
                result.append((root, quality, vector))
            }
        }
        return result
    }

    /// Hann-windowed magnitude spectrum (same zrop-packed vDSP convention as
    /// `SpectralFluxOnsetDetector`), folded into a 12-bin pitch-class histogram.
    private func chromagram(from window: [Float]) -> [Float] {
        let n = Self.fftSize
        let half = n / 2

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(window, 1, hannWindow, 1, &windowed, 1, vDSP_Length(n))

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

        var chroma = [Float](repeating: 0, count: 12)
        for k in 1..<half {
            let pc = binPitchClass[k]
            guard pc >= 0 else { continue }
            chroma[pc] += magnitudes[k]
        }
        return chroma
    }
}
