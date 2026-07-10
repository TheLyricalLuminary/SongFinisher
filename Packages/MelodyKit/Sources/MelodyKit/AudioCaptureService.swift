import Foundation
import AVFoundation
import os
import Domain

/// AVAudioEngine capture (docs/ARCHITECTURE.md §8): the tap copies hardware-rate samples
/// into the ring buffer and nothing else; a dedicated drain thread converts to 16 kHz mono
/// via AVAudioConverter and yields `AudioChunk`s. On iOS the session runs
/// `.playAndRecord` + `.measurement` so system AGC/EQ doesn't smear pitch.
public final class AudioCaptureService: AudioCapturing, @unchecked Sendable {
    // @unchecked: all mutable state is confined behind `stateLock`; the ring buffer is
    // internally synchronized. Verified by the start/stop tests.

    private let stateLock = OSAllocatedUnfairLock(uncheckedState: MutableState())

    private struct MutableState {
        var engine: AVAudioEngine?
        var drainThread: Thread?
        var running = false
        var chunkContinuation: AsyncStream<AudioChunk>.Continuation?
        var stateContinuation: AsyncStream<CaptureState>.Continuation?
    }

    private let ring = RingBuffer(capacity: 1 << 19)  // ~8 s @ 48 kHz mono

    public init() {}

    public var state: AsyncStream<CaptureState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            stateLock.withLockUnchecked { $0.stateContinuation = continuation }
        }
    }

    public func start() async throws(CaptureError) -> AsyncStream<AudioChunk> {
        let engine = AVAudioEngine()

        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            throw CaptureError.engineStartFailed("Audio session: \(error.localizedDescription)")
        }
        #endif

        let input = engine.inputNode
        let hardwareFormat = input.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw CaptureError.routeUnavailable
        }

        let ring = self.ring
        input.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { buffer, _ in
            // Tap discipline: mono-fold + copy into the ring. Nothing else.
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            ring.write(channels[0], count: frames)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(8))

        let thread = Thread { [ring, stateLock] in
            Self.drainLoop(ring: ring, hardwareFormat: hardwareFormat, stateLock: stateLock)
        }
        thread.name = "SongFinisher.AudioDrain"
        thread.qualityOfService = .userInteractive

        stateLock.withLockUnchecked {
            $0.engine = engine
            $0.drainThread = thread
            $0.running = true
            $0.chunkContinuation = continuation
            $0.stateContinuation?.yield(.listening)
        }

        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }

        thread.start()
        return stream
    }

    public func stop() async {
        let (engine, continuation): (AVAudioEngine?, AsyncStream<AudioChunk>.Continuation?) = stateLock.withLockUnchecked { s in
            guard s.running else { return (nil, nil) }
            s.running = false
            let engine = s.engine
            let continuation = s.chunkContinuation
            s.engine = nil
            s.drainThread = nil
            s.chunkContinuation = nil
            s.stateContinuation?.yield(.idle)
            return (engine, continuation)
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        continuation?.finish()
    }

    // MARK: - Drain thread

    private static func drainLoop(
        ring: RingBuffer,
        hardwareFormat: AVAudioFormat,
        stateLock: OSAllocatedUnfairLock<MutableState>
    ) {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: AnalysisChain.sampleRate, channels: 1, interleaved: false
        ), let monoHardware = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: hardwareFormat.sampleRate, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: monoHardware, to: targetFormat) else {
            _ = stateLock.withLockUnchecked { $0.stateContinuation?.yield(.failed("converter setup")) }
            return
        }

        let blockFrames = Int(hardwareFormat.sampleRate * 0.1)  // 100 ms per drain pass
        let scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: blockFrames)
        defer { scratch.deallocate() }

        var emittedSamples = 0

        while stateLock.withLockUnchecked({ $0.running }) {
            let read = ring.read(into: scratch, maxCount: blockFrames)
            if read == 0 {
                usleep(10_000)  // 10 ms: ring fills at ~4,800 samples/100 ms
                continue
            }

            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: monoHardware, frameCapacity: AVAudioFrameCount(read)),
                  let outBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: AVAudioFrameCount(Double(read) * targetFormat.sampleRate / hardwareFormat.sampleRate) + 64
                  ) else { continue }

            inBuffer.frameLength = AVAudioFrameCount(read)
            if let dst = inBuffer.floatChannelData?[0] {
                dst.update(from: scratch.baseAddress!, count: read)
            }

            // Input block is invoked synchronously within convert(to:) on this thread.
            nonisolated(unsafe) var fed = false
            nonisolated(unsafe) let feedBuffer = inBuffer
            var conversionError: NSError?
            converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return feedBuffer
            }
            if conversionError != nil { continue }

            let frames = Int(outBuffer.frameLength)
            guard frames > 0, let channel = outBuffer.floatChannelData?[0] else { continue }
            let samples = Array(UnsafeBufferPointer(start: channel, count: frames))
            let time = Double(emittedSamples) / AnalysisChain.sampleRate
            emittedSamples += frames

            stateLock.withLockUnchecked { $0.chunkContinuation }?.yield(AudioChunk(samples: samples, time: time))
        }
    }
}

/// Mic permission via AVAudioApplication (iOS 17+); trivially granted in host-side tests.
public struct MicPermissionService: PermissionChecking, Sendable {
    public init() {}

    public func currentMicPermission() async -> MicPermission {
        #if os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
        #else
        return .granted
        #endif
    }

    public func requestMicPermission() async -> MicPermission {
        #if os(iOS)
        let granted = await AVAudioApplication.requestRecordPermission()
        return granted ? .granted : .denied
        #else
        return .granted
        #endif
    }
}
