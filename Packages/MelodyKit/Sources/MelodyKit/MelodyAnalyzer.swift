import Foundation
import AVFoundation
import Domain

/// The `MelodyAnalyzing` conformance: a pure stream transformer. Mic capture, a memo file,
/// and a test fixture all feed the same `AnalysisChain` (docs/ARCHITECTURE.md §5, §8).
///
/// DSP runs inside the consuming task (userInitiated). The chain instance is created
/// inside the task, so its non-Sendable state stays confined by construction.
public struct MelodyAnalyzer: MelodyAnalyzing {
    public init() {}

    public func analyze(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<AnalysisEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let chain = AnalysisChain()
                for await chunk in chunks {
                    if Task.isCancelled { break }
                    chain.process(samples: chunk.samples) { continuation.yield($0) }
                }
                chain.flush { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Voice-memo path: decodes any AVAudioFile-readable format, resamples to 16 kHz mono,
    /// and runs the identical chain faster than real time. Section/hook clustering
    /// (DTW, docs/ARCHITECTURE.md §9) lands with the Voice Memo Resurrection phase —
    /// until then those fields are empty.
    public func analyzeFile(at url: URL, progress: @Sendable (Double) -> Void) async throws -> VoiceMemoAnalysis {
        let samples = try AudioFileDecoder.decode16kMono(url: url)
        let totalSamples = samples.count
        let duration = Double(totalSamples) / AnalysisChain.sampleRate

        let chain = AnalysisChain()
        var phrases: [Phrase] = []
        var lastTempo: TempoEstimate?

        let chunkSize = 16_000  // 1 s of audio per progress tick
        var offset = 0
        while offset < totalSamples {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, totalSamples)
            chain.process(samples: Array(samples[offset..<end])) { event in
                switch event {
                case .phraseCompleted(let phrase): phrases.append(phrase)
                case .tempoUpdated(let tempo): lastTempo = tempo
                default: break
                }
            }
            offset = end
            progress(Double(offset) / Double(max(1, totalSamples)))
        }
        chain.flush { event in
            if case .phraseCompleted(let phrase) = event { phrases.append(phrase) }
        }

        let tempo = lastTempo ?? TempoEstimate(bpm: 0, confidence: 0, beatPhase: 0)
        let prosody = DefaultProsodyDeriver()
        let specs = phrases.map { prosody.spec(for: $0, tempo: lastTempo, memoryHints: SessionMemory()) }

        // Duration-weighted average of per-phrase emotion distributions.
        var combined: [Emotion: Double] = [:]
        for (phrase, spec) in zip(phrases, specs) {
            for score in spec.emotions {
                combined[score.emotion, default: 0] += Double(score.confidence) * phrase.duration
            }
        }
        let totalWeight = combined.values.reduce(0, +)
        let dominant = totalWeight > 0
            ? combined.map { EmotionScore(emotion: $0.key, confidence: Float($0.value / totalWeight)) }.sortedByConfidence()
            : []

        return VoiceMemoAnalysis(
            duration: duration,
            tempo: tempo,
            phrases: phrases,
            specs: specs,
            sections: [],
            repeatedPhraseGroups: [],
            dominantEmotions: dominant
        )
    }
}

/// Decodes an audio file to 16 kHz mono Float32 via AVAudioConverter.
enum AudioFileDecoder {
    static func decode16kMono(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AnalysisChain.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let sourceCapacity: AVAudioFrameCount = 32_768
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceCapacity) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var output: [Float] = []
        var reachedEnd = false

        while !reachedEnd {
            let targetCapacity = AVAudioFrameCount(Double(sourceCapacity) * targetFormat.sampleRate / sourceFormat.sampleRate) + 1024
            guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
                throw CocoaError(.fileReadCorruptFile)
            }

            // The converter's input block is @Sendable-annotated in the SDK but is invoked
            // synchronously within convert(to:) on this thread — locals are safe to touch.
            nonisolated(unsafe) var readError: Error?
            nonisolated(unsafe) var fedThisPass = false
            nonisolated(unsafe) let source = sourceBuffer
            var conversionError: NSError?
            let status = converter.convert(to: targetBuffer, error: &conversionError) { _, outStatus in
                if fedThisPass {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                do {
                    source.frameLength = 0
                    try file.read(into: source)
                } catch {
                    readError = error
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if source.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                fedThisPass = true
                outStatus.pointee = .haveData
                return source
            }

            if let readError { throw readError }
            if let conversionError { throw conversionError }

            if targetBuffer.frameLength > 0, let channel = targetBuffer.floatChannelData?[0] {
                output.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(targetBuffer.frameLength)))
            }

            switch status {
            case .endOfStream:
                reachedEnd = true
            case .error:
                throw conversionError ?? CocoaError(.fileReadCorruptFile)
            default:
                if targetBuffer.frameLength == 0 && !fedThisPass { reachedEnd = true }
            }
        }

        return output
    }
}
