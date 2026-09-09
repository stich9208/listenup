import Foundation
@preconcurrency import AVFoundation
import ListenUpDomain
import ListenUpStorage

public final class MicrophoneCapture: @unchecked Sendable {
    public let chunkDurationSeconds: TimeInterval = 5
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "listenup.microphone.capture")
    private var file: AVAudioFile?
    private var framesInChunk: AVAudioFramePosition = 0
    private var currentPartialURL: URL?
    private var currentChunkStartMs: Int64 = 0
    private var totalFramesWritten: AVAudioFramePosition = 0
    private var counter = 0
    public private(set) var isRunning = false
    public var onFinalizedChunk: (@Sendable (URL) -> Void)?
    public var onFinalizedTimedChunk: (@Sendable (URL, Int64) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?
    public init() {}
    public func start(directory: URL) throws {
        guard !isRunning else { return }
        let input = engine.inputNode; let format = input.outputFormat(forBus: 0)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        counter = nextCounter(in: directory)
        try queue.sync {
            totalFramesWritten = 0
            currentChunkStartMs = 0
            file = try makeFile(directory: directory, format: format)
            framesInChunk = 0
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.queue.async { self.consume(buffer, directory: directory, format: format) }
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
    }
    private func consume(_ buffer: AVAudioPCMBuffer, directory: URL, format: AVAudioFormat) {
        do {
            try file?.write(from: buffer)
            framesInChunk += AVAudioFramePosition(buffer.frameLength)
            if Double(framesInChunk) / format.sampleRate >= chunkDurationSeconds {
                finalizeCurrentChunk()
                totalFramesWritten += framesInChunk
                currentChunkStartMs = Int64((Double(totalFramesWritten) / format.sampleRate * 1_000).rounded())
                file = try makeFile(directory: directory, format: format)
                framesInChunk = 0
            }
        } catch { preservePartialAndReleaseWriter(); onError?(error) }
    }
    private func makeFile(directory: URL, format: AVAudioFormat) throws -> AVAudioFile {
        repeat { counter += 1; currentPartialURL = directory.appendingPathComponent(String(format: "%06d.caf.partial", counter)) }
        while FileManager.default.fileExists(atPath: currentPartialURL!.path) || FileManager.default.fileExists(atPath: currentPartialURL!.deletingPathExtension().path)
        return try AVAudioFile(forWriting: currentPartialURL!, settings: format.settings)
    }
    private func finalizeCurrentChunk() {
        guard let partial = currentPartialURL else { file = nil; return }
        file = nil
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
    private func preservePartialAndReleaseWriter() { file = nil; currentPartialURL = nil }
    private func nextCounter(in directory: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { Int($0.prefix(6)) }.max() ?? 0
    }
}
