import AVFoundation
import AppKit
import XCTest
@testable import ListenUpApp
import ListenUpAudio
import ListenUpDomain

final class AppModelPauseTests: XCTestCase {
    @MainActor
    func testPauseResumeKeepsSameSessionAndExcludesPausedTime() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let model = fixture.model
        await model.startRecording()
        XCTAssertTrue(model.isRecording)
        let sessionID = model.session?.id
        try await fixture.emitAudio()
        await model.pauseRecording()
        XCTAssertTrue(model.recordingPaused)
        XCTAssertTrue(model.captureActive)
        XCTAssertEqual(model.session?.captureStatus, .paused)
        XCTAssertEqual(fixture.provider.stopCount, 1)
        XCTAssertEqual(model.session?.tracks.count, 1)
        let pausedTime = model.recordingPresentation.elapsedMs
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.recordingPresentation.elapsedMs, pausedTime)
        XCTAssertEqual(model.recordingPresentation.systemAudioLevel, 0)
        await model.resumeRecording()
        XCTAssertFalse(model.recordingPaused)
        XCTAssertEqual(model.session?.id, sessionID)
        XCTAssertEqual(model.session?.captureStatus, .recording)
        XCTAssertEqual(fixture.provider.startCount, 2)
        try await fixture.emitAudio()
        await model.stopRecording()
        XCTAssertEqual(model.session?.captureStatus, .stopped)
        XCTAssertEqual(model.session?.tracks.count, 2)
        XCTAssertFalse(model.captureActive)
        let spans = try XCTUnwrap(model.session?.tracks)
        XCTAssertNotEqual(spans[0].relativePath, spans[1].relativePath)
        XCTAssertGreaterThanOrEqual(spans[1].sessionStartMs, spans[0].sessionStartMs + spans[0].durationMs)
        XCTAssertLessThan(model.recordingPresentation.elapsedMs - pausedTime, 300, "paused wall time must not enter the resumed timeline")
        XCTAssertEqual(fixture.provider.stopCount, 2)
    }

    @MainActor
    func testStopWhilePausedKeepsSavedAudioAndDoesNotRestartCapture() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        await fixture.model.startRecording()
        try await fixture.emitAudio()
        await fixture.model.pauseRecording()
        let elapsed = fixture.model.recordingPresentation.elapsedMs
        await fixture.model.stopRecording()
        XCTAssertEqual(fixture.model.session?.captureStatus, .stopped)
        XCTAssertEqual(fixture.model.session?.tracks.count, 1)
        XCTAssertEqual(fixture.model.recordingPresentation.elapsedMs, elapsed)
        XCTAssertEqual(fixture.provider.startCount, 1)
        XCTAssertEqual(fixture.provider.stopCount, 1)
        XCTAssertFalse(fixture.model.recordingPaused)
    }

    @MainActor
    func testResumeFailureEndsSessionWithoutLosingPriorAudio() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        await fixture.model.startRecording()
        try await fixture.emitAudio()
        await fixture.model.pauseRecording()
        fixture.provider.failStart = true
        await fixture.model.resumeRecording()
        XCTAssertEqual(fixture.model.session?.captureStatus, .interrupted)
        XCTAssertEqual(fixture.model.session?.tracks.count, 1)
        XCTAssertFalse(fixture.model.captureActive)
        XCTAssertFalse(fixture.model.recordingPaused)
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertTrue(fixture.model.resultNotice.contains("재개하지 못했"))
    }

    @MainActor
    func testPauseFailureEndsSessionAndPreservesSavedAudio() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        await fixture.model.startRecording()
        try await fixture.emitAudio()
        fixture.provider.failStop = true
        await fixture.model.pauseRecording()
        XCTAssertEqual(fixture.model.session?.captureStatus, .interrupted)
        XCTAssertEqual(fixture.model.session?.tracks.count, 1)
        XCTAssertFalse(fixture.model.captureActive)
        XCTAssertFalse(fixture.model.isBusy)
    }

    func testPauseClockAccumulatesOnlyRunningSegments() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let first = CaptureElapsedFreeze.milliseconds(recordingBeganAt: start, captureQuiescedAt: start.addingTimeInterval(5), fallback: 0)
        let resumed = start.addingTimeInterval(60)
        let second = CaptureElapsedFreeze.milliseconds(recordingBeganAt: resumed, captureQuiescedAt: resumed.addingTimeInterval(3), fallback: first)
        XCTAssertEqual(second, 8_000)
        XCTAssertEqual(CaptureElapsedFreeze.milliseconds(recordingBeganAt: nil, captureQuiescedAt: resumed.addingTimeInterval(100), fallback: second), second)
    }

    @MainActor
    func testWidgetPositionRemainsReachableAfterDisplayChange() {
        let visible = NSRect(x: -1_000, y: 20, width: 1_000, height: 700)
        let point = RecordingIndicatorController.clampedOrigin(NSPoint(x: 2_000, y: -100), panelSize: NSSize(width: 58, height: 58), visibleFrame: visible)
        XCTAssertEqual(point, NSPoint(x: -58, y: 20))
        let retained = RecordingIndicatorController.clampedOrigin(NSPoint(x: -800, y: 400), panelSize: NSSize(width: 58, height: 58), visibleFrame: visible)
        XCTAssertEqual(retained, NSPoint(x: -800, y: 400))
    }
}

@MainActor
private struct Fixture {
    let root: URL
    let provider: PauseSampleProvider
    let model: AppModel

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let provider = PauseSampleProvider()
        self.provider = provider
        model = AppModel(rootDirectory: root, loadAPIKey: { nil }, makeSystemAudioRecorder: { SystemAudioRecorder(sampleProvider: provider) }, showsRecordingIndicator: false)
        model.title = "pause test"
        model.inputSource = .systemAudio
        model.availableApplications = [CaptureApplication(id: "test.app", name: "Test")]
        model.selectedApplicationID = "test.app"
    }

    func removeFiles() { try? FileManager.default.removeItem(at: root) }

    func emitAudio() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        pcm.frameLength = 480
        for frame in 0..<480 { pcm.floatChannelData![0][frame] = Float(sin(Double(frame) * 0.1)) * 0.2 }
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
        for index in 0..<10 {
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(value: Int64(index * 480), timescale: 48_000), decodeTimeStamp: .invalid)
            XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: 480, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
            let buffer = try XCTUnwrap(sample)
            XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
            XCTAssertEqual(CMSampleBufferSetDataReady(buffer), noErr)
            provider.emit(buffer)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class PauseSampleProvider: SystemAudioSampleProvider, @unchecked Sendable {
    var onError: (@Sendable (Error) -> Void)?
    private var handler: (@Sendable (CMSampleBuffer) -> Void)?
    var startCount = 0
    var stopCount = 0
    var failStart = false
    var failStop = false
    enum Failure: Error { case capture }
    func availableApplications() async throws -> [CaptureApplication] { [] }
    func start(application: CaptureApplication?, onSampleBuffer: @escaping @Sendable (CMSampleBuffer) -> Void) async throws {
        startCount += 1
        if failStart { throw Failure.capture }
        handler = onSampleBuffer
    }
    func stop() async throws {
        stopCount += 1
        handler = nil
        if failStop { throw Failure.capture }
    }
    func emit(_ sample: CMSampleBuffer) { handler?(sample) }
}
