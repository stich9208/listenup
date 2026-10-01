import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import ListenUpDomain

/// Writes ScreenCaptureKit audio to short, independently playable files. The
/// screen image delivered by ScreenCaptureKit is never registered as an output.
public final class SystemAudioRecorder: @unchecked Sendable {
    public let chunkDurationSeconds: Double = 15
    private let provider: any SystemAudioSampleProvider
    private let lock = NSLock()
    private var directory: URL?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var partialURL: URL?
    private var chunkStart: CMTime?
    private var firstPresentationTime: CMTime?
    private var counter = 0
    private var profile: RecordingQualityProfile = .transcriptionOptimized
    private let finishingGroup = DispatchGroup()
    private let meteringGate = CaptureMeteringGate()
    private let finalizer = OrderedFinalizer<PendingWriter>()
    private var nextFinalizationSequence = 0
    private enum Lifecycle { case idle, starting(UUID), running(UUID), stopping(UUID) }
    private var lifecycle: Lifecycle = .idle
    private var terminalOperation: Task<Result<Date, Error>, Never>?

    public var onFinalizedChunk: (@Sendable (URL) -> Void)?
    public var onFinalizedTimedChunk: (@Sendable (URL, Int64) -> Void)?
    public var onLevel: (@Sendable (Float) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?

    /// Original typed initializer retained for source and binary API clients.
    public convenience init(provider: ScreenCaptureProvider = .init()) {
        self.init(sampleProvider: provider)
    }

    /// Separate label keeps the injectable production seam from changing the
    /// legacy initializer's function type.
    public init(sampleProvider: any SystemAudioSampleProvider) {
        self.provider = sampleProvider
        sampleProvider.onError = { [weak self] error in self?.onError?(error) }
    }

    public func availableApplications() async throws -> [CaptureApplication] {
        try await provider.availableApplications()
    }

    /// Legacy entry point: existing clients continue to get the original
    /// high-quality 48 kHz/192 kbps behavior.
    public func start(directory: URL, application: CaptureApplication? = nil) async throws {
        try await start(directory: directory, profile: .highQuality, application: application)
    }

    public func start(directory: URL, profile: RecordingQualityProfile, application: CaptureApplication? = nil) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let token = UUID()
        let accepted = lock.withLock { () -> Bool in
            guard case .idle = lifecycle else { return false }
            lifecycle = .starting(token)
            self.directory = directory
            self.counter = Self.nextCounter(in: directory)
            self.firstPresentationTime = nil
            self.profile = profile
            self.meteringGate.reset()
            self.finalizer.resetAfterDraining()
            self.nextFinalizationSequence = 0
            return true
        }
        guard accepted else { throw ListenUpError.writeFailed("system audio recorder is not idle") }
        do {
            try await provider.start(application: application) { [weak self] sample in
                self?.consume(sample, ownedBy: token)
            }
            let becameRunning = lock.withLock { () -> Bool in
                guard case let .starting(current) = lifecycle, current == token else { return false }
                lifecycle = .running(token)
                return true
            }
            guard becameRunning else { throw CancellationError() }
        } catch {
            // Providers are allowed to deliver early samples before their
            // start call fails. Join the same terminal operation used by an
            // explicit stop so no writer or finalizer survives this failure.
            let quiescedAt = await terminalBarrier(for: token) ?? Date()
            throw SystemAudioRecorderStopError(captureQuiescedAt: quiescedAt, underlyingError: error)
        }
    }

    /// Compatibility entry point. Keep this exact `Void` signature for
    /// existing clients; AppModel uses the explicitly named barrier below.
    public func stop() async throws {
        _ = try await stopAndWaitForQuiescence()
    }

    /// Returns only after this run's provider has quiesced, its writer has
    /// detached/finalized, and every finalizer completion has been joined.
    @discardableResult
    public func stopAndWaitForQuiescence() async throws -> Date {
        let operation = lock.withLock { () -> Task<Result<Date, Error>, Never>? in
            switch lifecycle {
            case let .running(token), let .starting(token):
                lifecycle = .stopping(token)
                let operation: Task<Result<Date, Error>, Never> = Task { [weak self] in
                    guard let self else { return Result.failure(CancellationError()) }
                    return await self.performTerminalOperation(token: token)
                }
                terminalOperation = operation
                return operation
            case .stopping:
                return terminalOperation
            case .idle:
                return nil
            }
        }
        guard let operation else { throw ListenUpError.writeFailed("system audio recorder is not running") }
        switch await operation.value {
        case let .success(date): return date
        case let .failure(error): throw error
        }
    }

    private func terminalBarrier(for token: UUID) async -> Date? {
        let operation = lock.withLock { () -> Task<Result<Date, Error>, Never>? in
            switch lifecycle {
            case let .starting(current) where current == token,
                 let .running(current) where current == token:
                lifecycle = .stopping(token)
                let operation: Task<Result<Date, Error>, Never> = Task { [weak self] in
                    guard let self else { return Result.failure(CancellationError()) }
                    return await self.performTerminalOperation(token: token)
                }
                terminalOperation = operation
                return operation
            case let .stopping(current) where current == token:
                return terminalOperation
            default:
                return nil
            }
        }
        guard let operation else { return nil }
        switch await operation.value {
        case let .success(date): return date
        case .failure: return nil
        }
    }

    private func performTerminalOperation(token: UUID) async -> Result<Date, Error> {
        let providerResult: Result<Void, Error>
        do {
            try await provider.stop()
            providerResult = .success(())
        } catch {
            providerResult = .failure(error)
        }
        let captureQuiescedAt = Date()
        let pending = lock.withLock { detachWriter() }
        if let pending { finishInBackground(pending) }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [finishingGroup] in
                finishingGroup.wait()
                continuation.resume()
            }
        }
        onLevel?(0)
        lock.withLock {
            if case let .stopping(current) = lifecycle, current == token {
                lifecycle = .idle
                terminalOperation = nil
            }
        }
        switch providerResult {
        case .success: return .success(captureQuiescedAt)
        case let .failure(error): return .failure(SystemAudioRecorderStopError(captureQuiescedAt: captureQuiescedAt, underlyingError: error))
        }
    }

    private func consume(_ sample: CMSampleBuffer, ownedBy token: UUID) {
        guard CMSampleBufferDataIsReady(sample) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if meteringGate.shouldMeasure(at: now) {
            onLevel?(AudioLevelMetering.normalizedLevel(in: sample))
        }
        var oldWriter: PendingWriter?
        let appendError: Error? = lock.withLock {
                guard acceptsSamples(ownedBy: token) else { return nil }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                do {
                    if writer == nil { try beginChunk(at: pts, formatDescription: CMSampleBufferGetFormatDescription(sample)) }
                    if let start = chunkStart,
                       CMTimeGetSeconds(CMTimeSubtract(pts, start)) >= chunkDurationSeconds {
                        oldWriter = detachWriter()
                        try beginChunk(at: pts, formatDescription: CMSampleBufferGetFormatDescription(sample))
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

    private func beginChunk(at time: CMTime, formatDescription: CMFormatDescription?) throws {
        guard let directory else { throw ListenUpError.writeFailed("system audio directory") }
        repeat {
            counter += 1
            partialURL = directory.appendingPathComponent(String(format: "%06d.m4a.partial", counter))
        } while FileManager.default.fileExists(atPath: partialURL!.path)
            || FileManager.default.fileExists(atPath: partialURL!.deletingPathExtension().path)

        let writer = try AVAssetWriter(outputURL: partialURL!, fileType: .m4a)
        let sourceChannels = formatDescription.flatMap(CMAudioFormatDescriptionGetStreamBasicDescription)
        let channelCount = min(profile.maximumChannelCount, max(1, Int(sourceChannels?.pointee.mChannelsPerFrame ?? 1)))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: profile.sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: profile.bitRate,
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
        let sequence: Int
    }

    private func detachWriter() -> PendingWriter? {
        guard let writer, let writerInput, let partialURL else { return nil }
        let finalizedChunkStart = chunkStart
        self.writer = nil
        self.writerInput = nil
        self.partialURL = nil
        self.chunkStart = nil
        writerInput.markAsFinished()
        let relativeSeconds = firstPresentationTime.map { CMTimeGetSeconds(CMTimeSubtract(finalizedChunkStart ?? $0, $0)) } ?? 0
        let sessionStartMs = relativeSeconds.isFinite ? max(0, Int64((relativeSeconds * 1_000).rounded())) : 0
        let sequence = nextFinalizationSequence
        nextFinalizationSequence += 1
        return PendingWriter(writer: writer, input: writerInput, partialURL: partialURL, sessionStartMs: sessionStartMs, sequence: sequence)
    }

    private func finishInBackground(_ pending: PendingWriter) {
        finishingGroup.enter()
        let finalizer = finalizer
        let finishingGroup = finishingGroup
        pending.writer.finishWriting { [weak self, finalizer, finishingGroup] in
            finalizer.complete(sequence: pending.sequence, value: pending) { [weak self] pending in
                defer { finishingGroup.leave() }
                self?.publish(pending)
            }
        }
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

    private func acceptsSamples(ownedBy token: UUID) -> Bool {
        switch lifecycle {
        case let .starting(current), let .running(current): current == token
        case .idle, .stopping: false
        }
    }
}
