import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import ListenUpDomain

/// Writes ScreenCaptureKit audio to short, independently playable files. The
/// screen image delivered by ScreenCaptureKit is never registered as an output.
public final class SystemAudioRecorder: @unchecked Sendable {
    public let chunkDurationSeconds: Double = 5
    private let provider: ScreenCaptureProvider
    private let lock = NSLock()
    private var directory: URL?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var partialURL: URL?
    private var chunkStart: CMTime?
    private var firstPresentationTime: CMTime?
    private var counter = 0
    private let finishingGroup = DispatchGroup()

    public var onFinalizedChunk: (@Sendable (URL) -> Void)?
    public var onFinalizedTimedChunk: (@Sendable (URL, Int64) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?

    public init(provider: ScreenCaptureProvider = .init()) {
        self.provider = provider
        provider.onError = { [weak self] error in self?.onError?(error) }
    }

    public func availableApplications() async throws -> [CaptureApplication] {
        try await provider.availableApplications()
    }

    public func start(directory: URL, application: CaptureApplication? = nil) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lock.withLock {
            self.directory = directory
            self.counter = Self.nextCounter(in: directory)
            self.firstPresentationTime = nil
        }
        try await provider.start(application: application) { [weak self] sample in
            self?.consume(sample)
        }
    }

    public func stop() async throws {
        try await provider.stop()
        let pending = lock.withLock { detachWriter() }
        if let pending { try await finish(pending) }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [finishingGroup] in
                finishingGroup.wait()
                continuation.resume()
            }
        }
    }

    private func consume(_ sample: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sample) else { return }
        var oldWriter: PendingWriter?
        let appendError: Error? = lock.withLock {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                do {
                    if writer == nil { try beginChunk(at: pts) }
                    if let start = chunkStart,
                       CMTimeGetSeconds(CMTimeSubtract(pts, start)) >= chunkDurationSeconds {
                        oldWriter = detachWriter()
                        try beginChunk(at: pts)
                    }
                    guard let input = writerInput else { return ListenUpError.writeFailed("system audio writer missing") }
                    guard input.isReadyForMoreMediaData else { return ListenUpError.writeFailed("system audio backpressure") }
                    if !input.append(sample) { return writer?.error ?? ListenUpError.writeFailed("system audio append") }
                    return nil
                } catch {
                    return error
                }
        }
        if let oldWriter {
            finishInBackground(oldWriter)
        }
        if let appendError { onError?(appendError) }
    }

    private func beginChunk(at time: CMTime) throws {
        guard let directory else { throw ListenUpError.writeFailed("system audio directory") }
        repeat {
            counter += 1
            partialURL = directory.appendingPathComponent(String(format: "%06d.m4a.partial", counter))
        } while FileManager.default.fileExists(atPath: partialURL!.path)
            || FileManager.default.fileExists(atPath: partialURL!.deletingPathExtension().path)

        let writer = try AVAssetWriter(outputURL: partialURL!, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw ListenUpError.writeFailed("system audio encoder") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ListenUpError.writeFailed("system audio writer") }
        writer.startSession(atSourceTime: time)
        self.writer = writer
        self.writerInput = input
        self.chunkStart = time
        if firstPresentationTime == nil { firstPresentationTime = time }
    }

    private struct PendingWriter: @unchecked Sendable {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let partialURL: URL
        let sessionStartMs: Int64
    }

    private func detachWriter() -> PendingWriter? {
        guard let writer, let writerInput, let partialURL else { return nil }
        self.writer = nil
        self.writerInput = nil
        self.partialURL = nil
        self.chunkStart = nil
        writerInput.markAsFinished()
        let relativeSeconds = firstPresentationTime.map { CMTimeGetSeconds(CMTimeSubtract(chunkStart ?? $0, $0)) } ?? 0
        let sessionStartMs = relativeSeconds.isFinite ? max(0, Int64((relativeSeconds * 1_000).rounded())) : 0
        return PendingWriter(writer: writer, input: writerInput, partialURL: partialURL, sessionStartMs: sessionStartMs)
    }

    private func finishInBackground(_ pending: PendingWriter) {
        finishingGroup.enter()
        pending.writer.finishWriting { [self] in
            publish(pending)
            finishingGroup.leave()
        }
    }

    private func finish(_ pending: PendingWriter) async throws {
        await withCheckedContinuation { continuation in
            pending.writer.finishWriting { continuation.resume() }
        }
        try publishOrThrow(pending)
    }

    private func publish(_ pending: PendingWriter) {
        do { try publishOrThrow(pending) } catch { onError?(error) }
    }

    private func publishOrThrow(_ pending: PendingWriter) throws {
        guard pending.writer.status == .completed else {
            throw pending.writer.error ?? ListenUpError.writeFailed("system audio finalize")
        }
        let final = pending.partialURL.deletingPathExtension()
        try FileManager.default.moveItem(at: pending.partialURL, to: final)
        onFinalizedTimedChunk?(final, pending.sessionStartMs)
        onFinalizedChunk?(final)
    }

    private static func nextCounter(in directory: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { Int($0.prefix(6)) }.max() ?? 0
    }
}
