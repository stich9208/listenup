import Foundation
import Darwin
@preconcurrency import AVFoundation
import ListenUpDomain
import ListenUpStorage

public actor ReplayEngine {
    public private(set) var playheadMs: Int64 = 0
    public private(set) var isPlaying = false
    private var spans: [AudioSpan] = []
    private var liveHeadMs: Int64 = 0
    private let sessionDirectory: URL?
    private var playbackEngine: AVAudioEngine?
    private var playbackNodes: [AVAudioPlayerNode] = []
    private var playbackFiles: [AVAudioFile] = []
    private var playbackBeganAt: Date?
    private var playbackStartMs: Int64 = 0

    public init(spans: [AudioSpan] = [], sessionDirectory: URL? = nil) { self.spans = Self.confirmed(spans); self.sessionDirectory = sessionDirectory; liveHeadMs = spans.map { $0.sessionStartMs + $0.durationMs }.max() ?? 0 }
    public func update(spans: [AudioSpan], liveHeadMs: Int64? = nil) { self.spans = Self.confirmed(spans); if let liveHeadMs { self.liveHeadMs = liveHeadMs } else { self.liveHeadMs = self.spans.map { $0.sessionStartMs + $0.durationMs }.max() ?? 0 } }
    public func play() throws {
        guard let sessionDirectory else { throw ListenUpError.sourceUnavailable }
        let selected = playbackSpans().filter { $0.sessionStartMs + $0.durationMs > playheadMs }
        guard !selected.isEmpty else { throw ListenUpError.sourceUnavailable }
        let inputs = try selected.map { span -> (AudioSpan, AVAudioFile) in
            try DomainValidator.validateRelativePath(span.relativePath)
            let url = sessionDirectory.appendingPathComponent(span.relativePath)
            guard !url.lastPathComponent.hasSuffix(".partial"), FileManager.default.fileExists(atPath: url.path) else { throw ListenUpError.sourceUnavailable }
            return (span, try AVAudioFile(forReading: url))
        }
        stop()
        let engine = AVAudioEngine()
        let startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.1)
        let sourceCount = Set(selected.map(\.trackID)).count
        let gain = sourceCount > 1 ? Float(1 / sqrt(Double(sourceCount))) : 1
        var nodes: [AVAudioPlayerNode] = []
        for (span, file) in inputs {
            let node = AVAudioPlayerNode()
            node.volume = gain
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            let offsetMs = max(0, playheadMs - span.sessionStartMs) + span.inputOffsetMs
            let startingFrame = AVAudioFramePosition(Double(offsetMs) * file.processingFormat.sampleRate / 1_000)
            guard startingFrame < file.length else { continue }
            let frameCount = AVAudioFrameCount(min(Int64(UInt32.max), file.length - startingFrame))
            let delaySeconds = Double(max(0, span.sessionStartMs - playheadMs)) / 1_000
            let scheduledTime = AVAudioTime(hostTime: startHostTime + AVAudioTime.hostTime(forSeconds: delaySeconds))
            node.scheduleSegment(file, startingFrame: startingFrame, frameCount: frameCount, at: scheduledTime)
            nodes.append(node)
        }
        guard !nodes.isEmpty else { throw ListenUpError.sourceUnavailable }
        try engine.start()
        nodes.forEach { $0.play() }
        playbackEngine = engine
        playbackNodes = nodes
        playbackFiles = inputs.map(\.1)
        playbackStartMs = playheadMs
        playbackBeganAt = Date()
        isPlaying = true
    }
    public func stop() {
        refreshPlayheadFromPlayer()
        playbackNodes.forEach { $0.stop() }
        playbackEngine?.stop()
        playbackNodes.removeAll()
        playbackFiles.removeAll()
        playbackEngine = nil
        playbackBeganAt = nil
        isPlaying = false
    }
    public func rewind15Seconds() { playheadMs = max(0, playheadMs - 15_000) }
    public func seek(to milliseconds: Int64) { playheadMs = max(0, min(milliseconds, liveHeadMs)) }
    public func returnToLive() { playheadMs = liveHeadMs }
    public func currentSpan() -> AudioSpan? { spans.first { playheadMs >= $0.sessionStartMs && playheadMs < $0.sessionStartMs + $0.durationMs } }
    public func recordingHead() -> Int64 { liveHeadMs }
    public func refreshPlayheadFromPlayer() {
        guard let playbackBeganAt else { return }
        let advanced = Int64(Date().timeIntervalSince(playbackBeganAt) * 1_000)
        playheadMs = min(liveHeadMs, playbackStartMs + max(0, advanced))
    }
    private static func confirmed(_ spans: [AudioSpan]) -> [AudioSpan] {
        spans.filter { $0.durationMs > 0 && !$0.relativePath.hasSuffix(".partial") }.sorted { $0.sessionStartMs < $1.sessionStartMs }
    }

    /// A prepared mix supersedes source tracks. Otherwise every captured source
    /// is scheduled on the shared session timeline and AVAudioEngine mixes them.
    private func playbackSpans() -> [AudioSpan] {
        if spans.contains(where: { $0.trackID == "mixed" }) { return spans.filter { $0.trackID == "mixed" } }
        return spans.filter { $0.trackID == "microphone" || $0.trackID == "system" || $0.trackID == "imported" }
    }
}

public struct ImportedAudioFile: Sendable, Equatable { public let relativePath: String; public let sourceTrack: SourceTrack; public init(relativePath: String, sourceTrack: SourceTrack = .imported) { self.relativePath = relativePath; self.sourceTrack = sourceTrack } }
