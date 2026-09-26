import Foundation
@preconcurrency import AVFoundation
import ListenUpDomain
import ListenUpStorage

public final class MicrophoneCapture: @unchecked Sendable {
    public let chunkDurationSeconds: TimeInterval = 15
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "listenup.microphone.capture")
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var framesInChunk: AVAudioFramePosition = 0
    private var currentPartialURL: URL?
    private var currentChunkStartMs: Int64 = 0
    private var encodedFramesInChunk: AVAudioFramePosition = 0
    private var encodedTimeline = EncodedChunkTimeline()
    private var counter = 0
    private let meteringGate = CaptureMeteringGate()
    public private(set) var isRunning = false
    public var onFinalizedChunk: (@Sendable (URL) -> Void)?
    public var onFinalizedTimedChunk: (@Sendable (URL, Int64) -> Void)?
    public var onLevel: (@Sendable (Float) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?
    public init() {}
    /// Legacy entry point: existing clients continue to get the original
    /// high-quality 48 kHz/192 kbps behavior.
    public func start(directory: URL) throws {
        try start(directory: directory, profile: .highQuality)
    }

    public func start(directory: URL, profile: RecordingQualityProfile) throws {
        guard !isRunning else { return }
        let input = engine.inputNode; let format = input.outputFormat(forBus: 0)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        counter = nextCounter(in: directory)
        try queue.sync {
            encodedTimeline.reset()
            currentChunkStartMs = 0
            let writer = try makeFile(directory: directory, sourceFormat: format, profile: profile)
            file = writer
            converter = AVAudioConverter(from: format, to: writer.processingFormat)
            guard converter != nil else { throw ListenUpError.writeFailed("microphone audio conversion") }
            framesInChunk = 0
            encodedFramesInChunk = 0
            meteringGate.reset()
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.queue.async { self.consume(buffer, directory: directory, format: format, profile: profile) }
        }
        do {
            engine.prepare(); try engine.start(); isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            queue.sync { preservePartialAndReleaseWriter() }
            throw error
        }
    }
    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0); engine.stop(); isRunning = false
        queue.sync { finalizeCurrentChunk() }
        onLevel?(0)
    }
    private func consume(_ buffer: AVAudioPCMBuffer, directory: URL, format: AVAudioFormat, profile: RecordingQualityProfile) {
        do {
            let now = DispatchTime.now().uptimeNanoseconds
            if meteringGate.shouldMeasure(at: now) {
                onLevel?(AudioLevelMetering.normalizedLevel(in: buffer))
            }
            try write(buffer)
            framesInChunk += AVAudioFramePosition(buffer.frameLength)
            if Double(framesInChunk) / format.sampleRate >= chunkDurationSeconds {
                finalizeCurrentChunk()
                currentChunkStartMs = encodedTimeline.advance(afterWriting: encodedFramesInChunk, sampleRate: profile.sampleRate)
                let writer = try makeFile(directory: directory, sourceFormat: format, profile: profile)
                file = writer
                converter = AVAudioConverter(from: format, to: writer.processingFormat)
                guard converter != nil else { throw ListenUpError.writeFailed("microphone audio conversion") }
                framesInChunk = 0
                encodedFramesInChunk = 0
            }
        } catch { preservePartialAndReleaseWriter(); onError?(error) }
    }
    private func makeFile(directory: URL, sourceFormat: AVAudioFormat, profile: RecordingQualityProfile) throws -> AVAudioFile {
        repeat { counter += 1; currentPartialURL = directory.appendingPathComponent(String(format: "%06d.m4a.partial", counter)) }
        while FileManager.default.fileExists(atPath: currentPartialURL!.path) || FileManager.default.fileExists(atPath: currentPartialURL!.deletingPathExtension().path)
        return try MicrophoneM4AFileFactory.makeFile(at: currentPartialURL!, sourceFormat: sourceFormat, profile: profile)
    }
    private func finalizeCurrentChunk() {
        guard let partial = currentPartialURL, let file, let converter else { file = nil; return }
        do {
            try AudioConverterDrainer.drain(converter, to: file) { [weak self] frameCount in
                self?.encodedFramesInChunk += frameCount
            }
        }
        catch { preservePartialAndReleaseWriter(); onError?(error); return }
        self.file = nil
        self.converter = nil
        currentPartialURL = nil
        guard framesInChunk > 0 else {
            try? FileManager.default.removeItem(at: partial)
            return
        }
        let final = partial.deletingPathExtension()
        do {
            try FileManager.default.moveItem(at: partial, to: final)
            onFinalizedTimedChunk?(final, currentChunkStartMs)
            onFinalizedChunk?(final)
        }
        catch { onError?(error) }
    }
    private func preservePartialAndReleaseWriter() { file = nil; converter = nil; currentPartialURL = nil }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let file, let converter else { throw ListenUpError.writeFailed("microphone audio writer") }
        try AudioConverterDrainer.write(buffer, with: converter, to: file) { [weak self] frameCount in
            self?.encodedFramesInChunk += frameCount
        }
    }

}

enum AudioConverterDrainer {
    private static let maximumZeroProgressRetries = 3

    static func write(
        _ input: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to file: AVAudioFile,
        didWrite: (AVAudioFramePosition) -> Void
    ) throws {
        let capacity = outputCapacity(for: input, destination: file.processingFormat)
        var supplied = false
        var zeroProgressRetries = 0
        while true {
            guard let converted = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
                throw ListenUpError.writeFailed("microphone conversion buffer")
            }
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return input
            }
            guard status != .error else { throw conversionError ?? ListenUpError.writeFailed("microphone audio conversion") }
            if converted.frameLength > 0 {
                try file.write(from: converted)
                didWrite(AVAudioFramePosition(converted.frameLength))
                zeroProgressRetries = 0
            } else if status != .inputRanDry {
                zeroProgressRetries += 1
                guard zeroProgressRetries <= maximumZeroProgressRetries else {
                    throw ListenUpError.writeFailed("microphone converter made no progress")
                }
            }
            if status == .inputRanDry { return }
        }
    }

    static func drain(
        _ converter: AVAudioConverter,
        to file: AVAudioFile,
        didWrite: (AVAudioFramePosition) -> Void
    ) throws {
        let capacity = AVAudioFrameCount(max(1, Int(file.processingFormat.sampleRate * 0.1)))
        var zeroProgressRetries = 0
        while true {
            guard let converted = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
                throw ListenUpError.writeFailed("microphone drain buffer")
            }
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            guard status != .error else { throw conversionError ?? ListenUpError.writeFailed("microphone converter drain") }
            if converted.frameLength > 0 {
                try file.write(from: converted)
                didWrite(AVAudioFramePosition(converted.frameLength))
                zeroProgressRetries = 0
            } else if status != .endOfStream {
                zeroProgressRetries += 1
                guard zeroProgressRetries <= maximumZeroProgressRetries else {
                    throw ListenUpError.writeFailed("microphone converter drain made no progress")
                }
            }
            if status == .endOfStream { return }
        }
    }

    private static func outputCapacity(for input: AVAudioPCMBuffer, destination: AVAudioFormat) -> AVAudioFrameCount {
        let ratio = destination.sampleRate / input.format.sampleRate
        return AVAudioFrameCount(max(1, (Double(input.frameLength) * ratio).rounded(.up) + 32))
    }
}

private extension MicrophoneCapture {
    func nextCounter(in directory: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { Int($0.prefix(6)) }.max() ?? 0
    }
}

struct EncodedChunkTimeline {
    private var totalFrames: AVAudioFramePosition = 0

    mutating func reset() { totalFrames = 0 }

    mutating func advance(afterWriting frameCount: AVAudioFramePosition, sampleRate: Double) -> Int64 {
        totalFrames += frameCount
        return Int64((Double(totalFrames) / sampleRate * 1_000).rounded())
    }
}

enum MicrophoneM4AFileFactory {
    static func makeFile(at partialURL: URL, sourceFormat: AVAudioFormat, profile: RecordingQualityProfile) throws -> AVAudioFile {
        let channelCount = min(profile.maximumChannelCount, max(1, Int(sourceFormat.channelCount)))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: profile.sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRatePerChannelKey: NSNumber(value: UInt32(profile.bitRate / channelCount)),
            // The temporary suffix is .partial, so extension inference would
            // select the wrong container without this explicit declaration.
            AVAudioFileTypeKey: kAudioFileM4AType,
        ]
        return try AVAudioFile(forWriting: partialURL, settings: settings)
    }
}
