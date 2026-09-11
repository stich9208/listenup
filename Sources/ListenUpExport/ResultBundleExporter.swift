import Foundation
@preconcurrency import AVFoundation
import ListenUpDomain

public struct ResultBundleExporter {
    public init() {}

    /// Creates a user-facing ZIP containing exactly one M4A recording and one
    /// self-contained HTML result. Session manifests, revisions, request data,
    /// logs, and other internal files are intentionally excluded.
    public func export(
        session: Session,
        transcript: TranscriptRevision,
        summary: SummaryRevision,
        sessionDirectory: URL,
        destination: URL
    ) async throws {
        try DomainValidator.validate(session)
        try DomainValidator.validate(transcript)
        try DomainValidator.validate(summary, transcript: transcript)
        guard !session.tracks.isEmpty else { throw ListenUpError.missingReference("recording") }

        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("listenup-result-\(UUID().uuidString)", isDirectory: true)
        let stagingDirectory = temporaryRoot.appendingPathComponent("result", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let resultHTML = try ResultHTMLExporter().html(
            title: session.title,
            transcript: transcript,
            summary: summary
        )
        try Self.write(resultHTML, to: stagingDirectory.appendingPathComponent("transcript-summary.html"))

        let recordingURL = stagingDirectory.appendingPathComponent("recording.m4a")
        try await exportRecording(
            spans: session.tracks,
            sessionDirectory: sessionDirectory,
            destination: recordingURL
        )

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try Self.createArchive(from: stagingDirectory, destination: destination)
    }

    private func exportRecording(
        spans: [AudioSpan],
        sessionDirectory: URL,
        destination: URL
    ) async throws {
        let composition = AVMutableComposition()
        var tracks: [String: AVMutableCompositionTrack] = [:]

        for span in spans.sorted(by: {
            $0.sessionStartMs == $1.sessionStartMs
                ? $0.trackID < $1.trackID
                : $0.sessionStartMs < $1.sessionStartMs
        }) {
            try DomainValidator.validateRelativePath(span.relativePath)
            let sourceURL = sessionDirectory.appendingPathComponent(span.relativePath).standardizedFileURL
            let resolvedRoot = sessionDirectory.resolvingSymlinksInPath().path
            let resolvedSource = sourceURL.resolvingSymlinksInPath().path
            guard resolvedSource.hasPrefix(resolvedRoot + "/"),
                  FileManager.default.fileExists(atPath: resolvedSource)
            else { throw ListenUpError.sourceUnavailable }

            let asset = AVURLAsset(url: URL(fileURLWithPath: resolvedSource))
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                throw ListenUpError.sourceUnavailable
            }
            let assetDuration = try await asset.load(.duration)
            let sourceStart = Self.time(milliseconds: span.inputOffsetMs)
            let requestedDuration = Self.time(milliseconds: span.durationMs)
            let availableDuration = CMTimeSubtract(assetDuration, sourceStart)
            let duration = CMTimeMinimum(requestedDuration, availableDuration)
            guard CMTimeCompare(duration, .zero) > 0 else { continue }

            let compositionTrack: AVMutableCompositionTrack
            if let existing = tracks[span.trackID] {
                compositionTrack = existing
            } else {
                guard let created = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { throw ListenUpError.writeFailed("recording composition track") }
                tracks[span.trackID] = created
                compositionTrack = created
            }
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: sourceStart, duration: duration),
                of: sourceTrack,
                at: Self.time(milliseconds: span.sessionStartMs)
            )
        }

        guard !tracks.isEmpty else { throw ListenUpError.sourceUnavailable }
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else { throw ListenUpError.writeFailed("M4A exporter") }
        try await exporter.export(to: destination, as: .m4a)
    }

    private static func time(milliseconds: Int64) -> CMTime {
        CMTime(value: milliseconds, timescale: 1_000)
    }

    private static func write(_ value: String, to destination: URL) throws {
        guard let data = value.data(using: .utf8) else {
            throw ListenUpError.writeFailed(destination.lastPathComponent)
        }
        try data.write(to: destination, options: .atomic)
    }

    private static func createArchive(from directory: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = [
            "-q", "-j", destination.path,
            "recording.m4a", "transcript-summary.html",
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ListenUpError.writeFailed("result archive: \(error.localizedDescription)")
        }
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ListenUpError.writeFailed(message?.isEmpty == false ? message! : "result archive")
        }
    }
}
