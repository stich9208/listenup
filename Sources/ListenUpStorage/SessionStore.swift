import Foundation
import CryptoKit
import AudioToolbox
import ListenUpDomain

public struct JournalEntry: Codable, Sendable, Equatable {
    public let sequence: Int64
    public let eventID: UUID
    public let event: String
    public let references: [String]
    public let checksum: String?
    public let createdAt: Date
    public init(sequence: Int64, event: String, references: [String] = [], checksum: String? = nil, eventID: UUID = UUID(), createdAt: Date = Date()) {
        self.sequence = sequence; self.eventID = eventID; self.event = event; self.references = references; self.checksum = checksum; self.createdAt = createdAt
    }
}

public struct RecoveryReport: Sendable, Equatable {
    public var quarantinedJournalBytes: Int
    public var partialAudioFiles: [String]
    public var orphanedAudioFiles: [String]
    public var sessionWasMarkedInterrupted: Bool
    public init(quarantinedJournalBytes: Int = 0, partialAudioFiles: [String] = [], orphanedAudioFiles: [String] = [], sessionWasMarkedInterrupted: Bool = false) {
        self.quarantinedJournalBytes = quarantinedJournalBytes
        self.partialAudioFiles = partialAudioFiles
        self.orphanedAudioFiles = orphanedAudioFiles
        self.sessionWasMarkedInterrupted = sessionWasMarkedInterrupted
    }
}

public actor SessionStore {
    public let rootDirectory: URL
    public let sessionDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootDirectory: URL, sessionDirectory: URL? = nil) throws {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.sessionDirectory = (sessionDirectory ?? rootDirectory).standardizedFileURL
        self.encoder = Self.makeEncoder(); self.decoder = Self.makeDecoder()
        try FileManager.default.createDirectory(at: self.sessionDirectory, withIntermediateDirectories: true)
        for name in ["audio", "processing", "revisions", "exports"] { try FileManager.default.createDirectory(at: self.sessionDirectory.appendingPathComponent(name), withIntermediateDirectories: true) }
    }

    public static func create(in root: URL, session: Session) throws -> SessionStore {
        try DomainValidator.validate(session)
        let safe = sanitize(session.title)
        let suffix = String(session.id.uuidString.prefix(8)).lowercased()
        let dir = root.appendingPathComponent("\(safe)_\(suffix)", isDirectory: true)
        let store = try SessionStore(rootDirectory: root, sessionDirectory: dir)
        let encoder = Self.makeEncoder()
        try encoder.encode(session).write(to: dir.appendingPathComponent("session.json"), options: .atomic)
        return store
    }

    public static func reopen(_ directory: URL) throws -> SessionStore {
        let store = try SessionStore(rootDirectory: directory.deletingLastPathComponent(), sessionDirectory: directory)
        let decoder = Self.makeDecoder()
        let session = try decoder.decode(Session.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        try DomainValidator.validate(session)
        return store
    }

    public func readSession() throws -> Session { try readSessionSync() }

    /// Persists an immutable checkpoint before publishing it in the journal and
    /// finally advances the mutable manifest. Recovery can therefore replay a
    /// committed checkpoint when the process exits between the last two steps.
    public func saveSession(_ value: Session) throws {
        try DomainValidator.validate(value)
        _ = try repairJournalTailSync()
        let entries = try readJournalSync()
        var session = value
        let sequence = (entries.last?.sequence ?? 0) + 1
        session.lastJournalSequence = sequence
        session.revision = max(session.revision, try readSessionSync().revision + 1)
        // The UUID prevents an unjournaled checkpoint left by a crash from
        // blocking every later save at the same journal sequence.
        let relative = "processing/session-checkpoint-\(sequence)-\(UUID().uuidString).json"
        let data = try encoder.encode(session)
        try writeImmutableData(data, relativePath: relative)
        let checksum = Self.sha256(data)
        try appendJournalSync(JournalEntry(sequence: sequence, event: "session.checkpoint", references: [relative], checksum: checksum))
        try writeSessionSync(session)
    }

    @discardableResult
    public func updateSession(_ mutation: @Sendable (inout Session) throws -> Void) throws -> Session {
        var session = try readSessionSync()
        try mutation(&session)
        try saveSession(session)
        return try readSessionSync()
    }

    public func appendJournal(event: String, references: [String] = [], checksum: String? = nil) throws -> JournalEntry {
        _ = try repairJournalTailSync()
        let entries = try readJournalSync()
        let entry = JournalEntry(sequence: (entries.last?.sequence ?? 0) + 1, event: event, references: references, checksum: checksum)
        try appendJournalSync(entry)
        return entry
    }

    public func commit<T: Encodable>(_ value: T, relativePath: String) throws -> String {
        try DomainValidator.validateRelativePath(relativePath)
        guard !relativePath.isEmpty, !relativePath.hasSuffix("/") else { throw ListenUpError.invalidRelativePath(relativePath) }
        let target = sessionDirectory.appendingPathComponent(relativePath).standardizedFileURL
        guard target.path.hasPrefix(sessionDirectory.path + "/") else { throw ListenUpError.invalidRelativePath(relativePath) }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeImmutableData(encoder.encode(value), relativePath: relativePath)
        return relativePath
    }

    public func importFile(_ source: URL, track: SourceTrack = .imported) throws -> String {
        let name = Self.sanitize(source.lastPathComponent)
        let relative = "audio/imported/\(UUID().uuidString)_\(name)"
        try DomainValidator.validateRelativePath(relative)
        let target = sessionDirectory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        return relative
    }

    public func absoluteURL(for relativePath: String) throws -> URL {
        try DomainValidator.validateRelativePath(relativePath)
        let url = sessionDirectory.appendingPathComponent(relativePath).standardizedFileURL
        let resolvedRoot = sessionDirectory.resolvingSymlinksInPath().path
        let resolvedParent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard resolvedParent == resolvedRoot || resolvedParent.hasPrefix(resolvedRoot + "/") else { throw ListenUpError.invalidRelativePath(relativePath) }
        return url
    }

    public func read<T: Decodable>(_ type: T.Type, relativePath: String) throws -> T {
        let url = try absoluteURL(for: relativePath)
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    @discardableResult
    public func recover() throws -> RecoveryReport {
        let quarantined = try repairJournalTailSync()
        try replayJournalSync()
        let partials = partialAudioPaths()
        let orphanCandidates = try orphanedAudioPathsSync()
        let orphanRecovery = try recoverOrphanedAudioSync(orphanCandidates)
        let orphans = orphanRecovery.unresolved
        var session = try readSessionSync()
        var interrupted = false
        if (!partials.isEmpty || orphanRecovery.recoveredCount > 0) && session.captureStatus != .stopped {
            let lastEnd = session.tracks.map { $0.sessionStartMs + $0.durationMs }.max() ?? 0
            if !session.gaps.contains(where: { $0.startMs == lastEnd && $0.reason == .unknown }) {
                session.gaps.append(Gap(startMs: lastEnd, reason: .unknown))
            }
            session.captureStatus = .interrupted
            if session.processingStatus == .ready { session.processingStatus = .partial }
            session.revision += 1
            try writeSessionSync(session)
            interrupted = true
        }
        return RecoveryReport(quarantinedJournalBytes: quarantined, partialAudioFiles: partials, orphanedAudioFiles: orphans, sessionWasMarkedInterrupted: interrupted)
    }

    private func readSessionSync() throws -> Session { try decoder.decode(Session.self, from: Data(contentsOf: sessionDirectory.appendingPathComponent("session.json"))) }
    private func writeSessionSync(_ session: Session) throws {
        try DomainValidator.validate(session)
        let data = try encoder.encode(session)
        try data.write(to: sessionDirectory.appendingPathComponent("session.json"), options: .atomic)
    }

    private func writeImmutableData(_ data: Data, relativePath: String) throws {
        try DomainValidator.validateRelativePath(relativePath)
        let target = sessionDirectory.appendingPathComponent(relativePath).standardizedFileURL
        guard target.path.hasPrefix(sessionDirectory.path + "/") else { throw ListenUpError.invalidRelativePath(relativePath) }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw ListenUpError.writeFailed("immutable revision exists: \(relativePath)") }
        let temp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            let handle = try FileHandle(forWritingTo: temp)
            try handle.synchronize()
            try handle.close()
            try FileManager.default.moveItem(at: temp, to: target)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private func appendJournalSync(_ entry: JournalEntry) throws {
        let line = try encoder.encode(entry)
        let url = sessionDirectory.appendingPathComponent("journal.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.write(contentsOf: Data([10]))
        try handle.synchronize()
        try handle.close()
    }

    private func replayJournalSync() throws {
        let entries = try readJournalSync()
        var current = try readSessionSync()
        for entry in entries where entry.sequence > current.lastJournalSequence && entry.event == "session.checkpoint" {
            guard let relative = entry.references.first else { continue }
            try DomainValidator.validateRelativePath(relative)
            let url = sessionDirectory.appendingPathComponent(relative).standardizedFileURL
            guard url.path.hasPrefix(sessionDirectory.path + "/"), let data = try? Data(contentsOf: url) else { continue }
            guard entry.checksum == nil || entry.checksum == Self.sha256(data) else { continue }
            guard let candidate = try? decoder.decode(Session.self, from: data), candidate.lastJournalSequence == entry.sequence else { continue }
            try DomainValidator.validate(candidate)
            current = candidate
        }
        if current != (try readSessionSync()) { try writeSessionSync(current) }
    }

    private func readJournalSync() throws -> [JournalEntry] {
        let url = sessionDirectory.appendingPathComponent("journal.jsonl")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        var entries: [JournalEntry] = []
        for line in data.split(separator: 10, omittingEmptySubsequences: true) {
            let entry = try decoder.decode(JournalEntry.self, from: Data(line))
            guard entry.sequence == Int64(entries.count + 1) else { throw ListenUpError.writeFailed("journal sequence") }
            entries.append(entry)
        }
        return entries
    }

    @discardableResult
    private func repairJournalTailSync() throws -> Int {
        let url = sessionDirectory.appendingPathComponent("journal.jsonl")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return 0 }
        var validLines: [Data] = []
        var previousEnd = data.startIndex
        var invalidStart: Data.Index?
        var expected: Int64 = 1
        var needsFinalNewline = false
        while previousEnd < data.endIndex {
            let newline = data[previousEnd...].firstIndex(of: 10)
            let end = newline ?? data.endIndex
            let line = data[previousEnd..<end]
            if !line.isEmpty,
               let entry = try? decoder.decode(JournalEntry.self, from: Data(line)),
               entry.sequence == expected {
                validLines.append(Data(line)); expected += 1
            } else if !line.isEmpty {
                invalidStart = previousEnd; break
            }
            guard let newline else { needsFinalNewline = !line.isEmpty; break }
            previousEnd = data.index(after: newline)
        }
        if invalidStart == nil, needsFinalNewline {
            var repaired = data
            repaired.append(10)
            try repaired.write(to: url, options: .atomic)
            return 0
        }
        guard let invalidStart else { return 0 }
        let corrupt = Data(data[invalidStart...])
        let quarantine = sessionDirectory.appendingPathComponent("journal.corrupt-\(Int(Date().timeIntervalSince1970)).bin")
        try corrupt.write(to: quarantine, options: .atomic)
        var repaired = validLines.reduce(into: Data()) { partial, line in partial.append(line); partial.append(10) }
        if repaired.isEmpty { repaired = Data() }
        try repaired.write(to: url, options: .atomic)
        return corrupt.count
    }

    private func partialAudioPaths() -> [String] {
        let audio = sessionDirectory.appendingPathComponent("audio")
        guard let enumerator = FileManager.default.enumerator(at: audio, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.lastPathComponent.hasSuffix(".partial") else { return nil }
            return relativePath(for: url)
        }.sorted()
    }

    private func orphanedAudioPathsSync() throws -> [String] {
        let registered = Set(try readSessionSync().tracks.map(\.relativePath))
        let audio = sessionDirectory.appendingPathComponent("audio")
        guard let enumerator = FileManager.default.enumerator(at: audio, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  !url.lastPathComponent.hasSuffix(".partial"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            guard let relative = relativePath(for: url) else { return nil }
            return registered.contains(relative) ? nil : relative
        }.sorted()
    }

    private func relativePath(for url: URL) -> String? {
        let root = sessionDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let child = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard child.hasPrefix(root + "/") else { return nil }
        return String(child.dropFirst(root.count + 1))
    }

    private func recoverOrphanedAudioSync(_ paths: [String]) throws -> (unresolved: [String], recoveredCount: Int) {
        guard !paths.isEmpty else { return ([], 0) }
        var session = try readSessionSync()
        var unresolved: [String] = []
        var recovered = 0
        for relative in paths {
            let components = relative.split(separator: "/")
            let trackID: String
            if components.contains("microphone") { trackID = "microphone" }
            else if components.contains("system") { trackID = "system" }
            else if components.contains("imported") { trackID = "imported" }
            else { unresolved.append(relative); continue }
            let url = sessionDirectory.appendingPathComponent(relative)
            do {
                let metadata = try Self.audioMetadata(url)
                let startMs = session.tracks.filter { $0.trackID == trackID }
                    .map { $0.sessionStartMs + $0.durationMs }.max() ?? 0
                session.tracks.append(AudioSpan(
                    trackID: trackID,
                    relativePath: relative,
                    durationMs: metadata.durationMs,
                    sessionStartMs: startMs,
                    sampleRate: metadata.sampleRate,
                    frameCount: metadata.frameCount,
                    checksum: try Self.sha256(url)
                ))
                recovered += 1
            } catch {
                unresolved.append(relative)
            }
        }
        if recovered > 0 { try saveSession(session) }
        return (unresolved, recovered)
    }
    private static func sanitize(_ value: String) -> String { let filtered = value.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" ? Character($0) : "_" }; let s = String(filtered).trimmingCharacters(in: CharacterSet(charactersIn: "_.-")); return String((s.isEmpty ? "session" : s).prefix(80)) }
    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func audioMetadata(_ url: URL) throws -> (sampleRate: Double, frameCount: Int64, durationMs: Int64) {
        var audioFile: AudioFileID?
        let openStatus = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile)
        guard openStatus == noErr, let audioFile else { throw ListenUpError.writeFailed("unreadable recovered audio") }
        defer { AudioFileClose(audioFile) }

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(audioFile, kAudioFilePropertyDataFormat, &formatSize, &format) == noErr,
              format.mSampleRate > 0 else { throw ListenUpError.writeFailed("recovered audio format") }

        var duration: Double = 0
        var durationSize = UInt32(MemoryLayout<Double>.size)
        let durationStatus = AudioFileGetProperty(audioFile, kAudioFilePropertyEstimatedDuration, &durationSize, &duration)
        if durationStatus != noErr || !duration.isFinite || duration <= 0 {
            var packetCount: UInt64 = 0
            var packetCountSize = UInt32(MemoryLayout<UInt64>.size)
            guard AudioFileGetProperty(audioFile, kAudioFilePropertyAudioDataPacketCount, &packetCountSize, &packetCount) == noErr,
                  packetCount > 0, format.mFramesPerPacket > 0 else {
                throw ListenUpError.writeFailed("recovered audio duration")
            }
            duration = Double(packetCount) * Double(format.mFramesPerPacket) / format.mSampleRate
        }
        let frames = Int64((duration * format.mSampleRate).rounded())
        return (format.mSampleRate, frames, Int64((duration * 1_000).rounded()))
    }
    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let value = try container.decode(String.self)
            let precise = ISO8601DateFormatter()
            precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = precise.date(from: value) { return date }
            let compatible = ISO8601DateFormatter()
            compatible.formatOptions = [.withInternetDateTime]
            guard let date = compatible.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid encoded date")
            }
            return date
        }
        return decoder
    }
}
