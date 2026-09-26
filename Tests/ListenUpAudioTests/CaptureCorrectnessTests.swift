import AVFoundation
import XCTest
@testable import ListenUpAudio
import ListenUpDomain

final class CaptureCorrectnessTests: XCTestCase {
    func testControllableProviderStopErrorStillLeavesRecorderReusable() async throws {
        let provider = ControllableProvider()
        let recorder = SystemAudioRecorder(sampleProvider: provider)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await recorder.start(directory: directory)
        do {
            try await recorder.start(directory: directory)
            XCTFail("double start must be rejected")
        } catch {}

        provider.failStop = true
        do {
            try await recorder.stop()
            XCTFail("provider error must remain observable after recorder cleanup")
        } catch let error as SystemAudioRecorderStopError {
            XCTAssertLessThanOrEqual(abs(error.captureQuiescedAt.timeIntervalSinceNow), 1)
        }
        provider.failStop = false
        try await recorder.start(directory: directory)
        try await recorder.stop()
    }

    func testControllableProviderStopDuringStartDoesNotLeaveRecorderRunning() async throws {
        let provider = ControllableProvider(blockStart: true)
        let recorder = SystemAudioRecorder(sampleProvider: provider)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let start = Task { try await recorder.start(directory: directory) }
        await provider.waitUntilStartEntered()
        try await recorder.stop()
        provider.releaseStart()
        do {
            try await start.value
            XCTFail("start interrupted by stop must not report running")
        } catch let error as SystemAudioRecorderStopError {
            XCTAssertTrue(error.underlyingError is CancellationError)
            XCTAssertLessThanOrEqual(abs(error.captureQuiescedAt.timeIntervalSinceNow), 1)
        }
    }
    func testPartialPathCreatesDecodableM4AForEachProfile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try pcmFormat(sampleRate: 48_000)

        for profile in RecordingQualityProfile.allCases {
            let url = directory.appendingPathComponent("\(profile.rawValue).m4a.partial")
            do {
                let file = try MicrophoneM4AFileFactory.makeFile(at: url, sourceFormat: source, profile: profile)
                try file.write(from: try pcmBuffer(format: file.processingFormat, frameCount: 480))
            }
            let decoded = try AVAudioFile(forReading: url)
            XCTAssertEqual(decoded.processingFormat.sampleRate, profile.sampleRate, accuracy: 1)
            XCTAssertGreaterThan(decoded.length, 0)
            // AAC-LC packet priming/padding is bounded by one 1024-frame
            // packet; session starts are instead derived from written PCM.
            XCTAssertLessThanOrEqual(abs(decoded.length - 480), 1_024)
        }
    }

    func testConverterDrainWritesPendingOutputAndTimelineIsContinuous() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try pcmFormat(sampleRate: 48_000)
        let destination = try pcmFormat(sampleRate: 24_000)
        let url = directory.appendingPathComponent("converted.caf")
        let file = try AVAudioFile(forWriting: url, settings: destination.settings)
        guard let converter = AVAudioConverter(from: source, to: destination) else {
            return XCTFail("converter unavailable")
        }
        let input = try pcmBuffer(format: source, frameCount: 480)
        var supplied = false
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: 64))
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        try file.write(from: output)
        var drainedFrames: AVAudioFramePosition = 0
        try AudioConverterDrainer.drain(converter, to: file) { drainedFrames += $0 }
        XCTAssertNil(error)
        XCTAssertGreaterThan(drainedFrames, 0)
        XCTAssertEqual(file.length, 240, accuracy: 1)

        var timeline = EncodedChunkTimeline()
        XCTAssertEqual(timeline.advance(afterWriting: 360_000, sampleRate: 24_000), 15_000)
        XCTAssertEqual(timeline.advance(afterWriting: 360_000, sampleRate: 24_000), 30_000)
        XCTAssertEqual(timeline.advance(afterWriting: 24_000, sampleRate: 24_000), 31_000)
    }

    func testMeteringGateAndInactiveRelayRetainPeaksWithoutPublication() {
        let gate = CaptureMeteringGate()
        XCTAssertTrue(gate.shouldMeasure(at: 0))
        XCTAssertFalse(gate.shouldMeasure(at: 99_999_999))
        XCTAssertTrue(gate.shouldMeasure(at: 100_000_000))

        let relay = CaptureMeterRelay()
        let publications = LockedBox<[CaptureMeterSnapshot]>([])
        relay.onSnapshot = { snapshot in publications.mutate { values in values.append(snapshot) } }
        relay.setActive(false, at: 0)
        relay.record(0.8, from: .microphone, at: 100_000_000)
        relay.record(0.4, from: .systemAudio, at: 200_000_000)
        XCTAssertTrue(publications.value.isEmpty)
        XCTAssertEqual(relay.snapshot().microphonePeak, 0.8)
        XCTAssertEqual(relay.snapshot().systemAudioPeak, 0.4)

        relay.setActive(true, at: 300_000_000)
        XCTAssertEqual(publications.value.count, 1)
        XCTAssertEqual(publications.value[0].microphonePeak, 0.8)
        relay.record(0.9, from: .microphone, at: 350_000_000)
        XCTAssertEqual(publications.value.count, 1)
        relay.record(0.9, from: .microphone, at: 400_000_000)
        XCTAssertEqual(publications.value.count, 2)
        relay.resetForNewRecording()
        XCTAssertEqual(relay.snapshot().microphonePeak, 0)
    }

    func testMeterRelayDeactivationWaitsForSelectedCallback() async {
        let relay = CaptureMeterRelay()
        let callbackStarted = expectation(description: "callback started")
        let allowCallbackReturn = DispatchSemaphore(value: 0)
        let callbackReturned = LockedBox(false)
        relay.onSnapshot = { _ in
            callbackStarted.fulfill()
            allowCallbackReturn.wait()
            callbackReturned.mutate { $0 = true }
        }
        let record = Task.detached { relay.record(0.5, from: .microphone, at: 0) }
        await fulfillment(of: [callbackStarted], timeout: 1)
        let deactivate = Task.detached { relay.setActive(false, at: 1) }
        XCTAssertFalse(callbackReturned.value)
        allowCallbackReturn.signal()
        await record.value
        await deactivate.value
        // setActive(false) cannot return until an already-selected callback
        // has returned, so it cannot create a publication afterwards.
        XCTAssertTrue(callbackReturned.value)
    }

    func testFinalizerDeliversOutOfOrderCompletionsInCaptureOrder() {
        let finalizer = OrderedFinalizer<Int>()
        let done = expectation(description: "ordered")
        done.expectedFulfillmentCount = 3
        let received = LockedBox<[Int]>([])
        let deliver: @Sendable (Int) -> Void = { value in
            received.mutate { $0.append(value) }
            done.fulfill()
        }
        finalizer.complete(sequence: 2, value: 2, deliver: deliver)
        finalizer.complete(sequence: 0, value: 0, deliver: deliver)
        finalizer.complete(sequence: 1, value: 1, deliver: deliver)
        wait(for: [done], timeout: 1)
        XCTAssertEqual(received.value, [0, 1, 2])
    }

    func testFinalizedEventRelayDrainsOnlyAfterFIFOAcknowledgement() async {
        let relay = FinalizedEventRelay<Int>()
        let received = LockedBox<[Int]>([])
        let worker = DispatchQueue(label: "test.finalized-event-consumer")
        let consume: @Sendable () -> Void = {
            worker.async {
                while let event = relay.next() {
                    received.mutate { $0.append(event) }
                    _ = relay.acknowledgeOne()
                }
            }
        }

        relay.submit(1, startConsumer: consume)
        relay.submit(2, startConsumer: consume)
        await relay.drain()
        XCTAssertEqual(received.value, [1, 2])
    }

    func testM4AConverterPreservesAggregateDurationAcrossMultipleChunks() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try pcmFormat(sampleRate: 48_000)
        let profile = RecordingQualityProfile.transcriptionOptimized
        var decodedFrames: AVAudioFramePosition = 0

        for chunk in 0..<2 {
            let url = directory.appendingPathComponent("chunk-\(chunk).m4a.partial")
            let input = try pcmBuffer(format: source, frameCount: 48_000)
            do {
                let file = try MicrophoneM4AFileFactory.makeFile(at: url, sourceFormat: source, profile: profile)
                let converter = try XCTUnwrap(AVAudioConverter(from: source, to: file.processingFormat))
                try AudioConverterDrainer.write(input, with: converter, to: file) { _ in }
                try AudioConverterDrainer.drain(converter, to: file) { _ in }
            }
            decodedFrames += try AVAudioFile(forReading: url).length
        }

        let expectedFrames = AVAudioFramePosition(profile.sampleRate * 2)
        // AAC-LC can add/remove one 1024-frame packet at each independent
        // chunk boundary. Aggregate playback remains inside that tolerance.
        XCTAssertLessThanOrEqual(abs(decodedFrames - expectedFrames), 2_048)
    }

    func testLegacyCaptureStartSignaturesRemainAvailable() {
        let microphone = MicrophoneCapture()
        let _: (URL) throws -> Void = microphone.start(directory:)
        let recorder = SystemAudioRecorder()
        let _: (ScreenCaptureProvider) -> SystemAudioRecorder = SystemAudioRecorder.init(provider:)
        let _: (any SystemAudioSampleProvider) -> SystemAudioRecorder = SystemAudioRecorder.init(sampleProvider:)
        let _: (URL, CaptureApplication?) async throws -> Void = recorder.start(directory:application:)
        let _: () async throws -> Void = recorder.stop
        let _: () async throws -> Date = recorder.stopAndWaitForQuiescence
    }

    func testSampleQueueDrainWaitsForAlreadyEnqueuedCallback() async {
        let sampleQueue = DispatchQueue(label: "test.sample-delivery")
        let delivered = LockedBox(false)
        sampleQueue.async { delivered.mutate { $0 = true } }
        await SampleQueueQuiescer.drain(sampleQueue)
        XCTAssertTrue(delivered.value)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pcmFormat(sampleRate: Double) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
    }

    private func pcmBuffer(format: AVAudioFormat, frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        return buffer
    }
}

private final class ControllableProvider: SystemAudioSampleProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let blockStart: Bool
    private var enteredStart = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    var failStop = false
    var onError: (@Sendable (Error) -> Void)?

    init(blockStart: Bool = false) { self.blockStart = blockStart }

    func availableApplications() async throws -> [CaptureApplication] { [] }

    func start(application: CaptureApplication?, onSampleBuffer: @escaping @Sendable (CMSampleBuffer) -> Void) async throws {
        guard blockStart else { return }
        await withCheckedContinuation { continuation in
            lock.withLock {
                enteredStart = true
                startContinuation = continuation
            }
        }
    }

    func stop() async throws {
        if lock.withLock({ failStop }) { throw TestProviderError.stopFailed }
    }

    func waitUntilStartEntered() async {
        while !lock.withLock({ enteredStart }) { await Task.yield() }
    }

    func releaseStart() { lock.withLock { startContinuation?.resume(); startContinuation = nil } }
}

private enum TestProviderError: Error { case stopFailed }

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }
    var value: Value { lock.withLock { storage } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&storage) } }
}
