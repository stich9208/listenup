import XCTest
import AudioToolbox
@testable import ListenUpStorage
import ListenUpDomain

final class SessionStoreTests: XCTestCase {
    func testRoundTripJournalAndImmutableRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(title: "강의/../demo", purpose: .lecture, inputSource: .microphone)
        let store = try SessionStore.create(in: root, session: session)
        let storedSession = try await store.readSession()
        XCTAssertEqual(storedSession, session)
        let entry = try await store.appendJournal(event: "created", references: ["session.json"])
        XCTAssertEqual(entry.sequence, 1)
        let revision = AnnotationRevision(id: "annotations-r001")
        _ = try await store.commit(revision, relativePath: "revisions/annotations-r001.json")
        do { _ = try await store.commit(revision, relativePath: "revisions/annotations-r001.json"); XCTFail("revision overwrite") } catch { }
        do { _ = try await store.absoluteURL(for: "../outside"); XCTFail("path traversal") } catch { }
    }

    func testRepairsTruncatedJournalBeforeAppending() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore.create(in: root, session: Session(title: "test", purpose: .meeting, inputSource: .microphone))
        _ = try await store.appendJournal(event: "one")
        let journal = await store.sessionDirectory.appendingPathComponent("journal.jsonl")
        let handle = try FileHandle(forWritingTo: journal); try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken".utf8)); try handle.close()
        let next = try await store.appendJournal(event: "two")
        XCTAssertEqual(next.sequence, 2)
    }

    func testRepairsValidJournalTailWithoutNewline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore.create(in: root, session: Session(title: "test", purpose: .meeting, inputSource: .microphone))
        let first = try await store.appendJournal(event: "one")
        let journal = await store.sessionDirectory.appendingPathComponent("journal.jsonl")
        var bytes = try Data(contentsOf: journal)
        XCTAssertEqual(bytes.removeLast(), 10)
        try bytes.write(to: journal)
        let second = try await store.appendJournal(event: "two")
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(second.sequence, 2)
    }

    func testRecoveryReplaysPublishedCheckpointWhenManifestIsStale() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = Session(title: "initial", purpose: .meeting, inputSource: .microphone)
        let store = try SessionStore.create(in: root, session: initial)
        var changed = initial
        changed.title = "committed"
        try await store.saveSession(changed)

        let directory = await store.sessionDirectory
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(initial).write(to: directory.appendingPathComponent("session.json"), options: .atomic)

        let reopened = try SessionStore.reopen(directory)
        _ = try await reopened.recover()
        let recovered = try await reopened.readSession()
        XCTAssertEqual(recovered.title, "committed")
        XCTAssertEqual(recovered.lastJournalSequence, 1)
    }

    func testRecoveryRegistersFinalizedAudioLeftBeforeManifestUpdate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore.create(in: root, session: Session(title: "recover-audio", purpose: .meeting, inputSource: .microphone, captureStatus: .recording))
        let directory = await store.sessionDirectory
        let audioDirectory = directory.appendingPathComponent("audio/microphone", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let url = audioDirectory.appendingPathComponent("000001.wav")
        try Self.silentPCM16WAV(frameCount: 1_600, sampleRate: 16_000).write(to: url)
        var fixtureAudioFile: AudioFileID?
        let fixtureStatus = AudioFileOpenURL(url as CFURL, .readPermission, 0, &fixtureAudioFile)
        XCTAssertEqual(fixtureStatus, noErr, "generated WAV must be readable (OSStatus \(fixtureStatus))")
        if let fixtureAudioFile { AudioFileClose(fixtureAudioFile) }
        let metadata = try SessionStore.audioMetadata(url)
        XCTAssertEqual(metadata.durationMs, 100)

        let report = try await store.recover()
        let recovered = try await store.readSession()
        XCTAssertTrue(report.orphanedAudioFiles.isEmpty)
        XCTAssertEqual(recovered.tracks.count, 1)
        let recoveredSpan = try XCTUnwrap(recovered.tracks.first)
        XCTAssertEqual(recoveredSpan.trackID, "microphone")
        XCTAssertEqual(recoveredSpan.relativePath, "audio/microphone/000001.wav")
        XCTAssertEqual(recovered.captureStatus, .interrupted)
    }

    private static func silentPCM16WAV(frameCount: Int, sampleRate: Int) -> Data {
        let payloadBytes = frameCount * 2
        var result = Data("RIFF".utf8)
        append(UInt32(36 + payloadBytes), to: &result)
        result.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &result)
        append(UInt16(1), to: &result)
        append(UInt16(1), to: &result)
        append(UInt32(sampleRate), to: &result)
        append(UInt32(sampleRate * 2), to: &result)
        append(UInt16(2), to: &result)
        append(UInt16(16), to: &result)
        result.append(Data("data".utf8))
        append(UInt32(payloadBytes), to: &result)
        result.append(Data(repeating: 0, count: payloadBytes))
        return result
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
