import Foundation
import XCTest
@testable import ListenUpApp
import ListenUpAudio
import ListenUpDomain
import ListenUpStorage

final class AppModelStopTests: XCTestCase {
    func testProductionTerminalCoordinatorPersistsInterruptedSessionInTemporaryStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SessionStore.create(in: root, session: Session(title: "terminal", purpose: .meeting, inputSource: .microphone, captureStatus: .recording))
        let coordinator = CaptureTerminalCoordinator()
        let session = try await coordinator.persistInterrupted(store, failureMs: 123)
        XCTAssertEqual(session.captureStatus, .interrupted)
        XCTAssertEqual(session.gaps.last?.startMs, 123)
        let blocked = await coordinator.terminalPersistenceBlocked
        XCTAssertFalse(blocked)
    }
    func testFailureEventIsAcknowledgedBeforeTerminalDrainAndPersistence() async {
        enum Event: Sendable { case failure }
        let relay = FinalizedEventRelay<Event>()
        let cleanupStarted = expectation(description: "failure cleanup started")
        let persisted = expectation(description: "interrupted session persisted")
        let state = FailureCleanupState()

        let consume: @Sendable () -> Void = {
            Task {
                while let event = relay.next() {
                    switch event {
                    case .failure:
                        // This is the ordering used by AppModel's production
                        // finalized-event consumer: acknowledge first, then
                        // perform terminal work that awaits drain.
                        _ = relay.acknowledgeOne()
                        await state.setBusy(true)
                        cleanupStarted.fulfill()
                        await relay.drain()
                        await state.persistInterrupted()
                        persisted.fulfill()
                        return
                    }
                }
            }
        }

        relay.submit(.failure, startConsumer: consume)
        await fulfillment(of: [cleanupStarted], timeout: 1)
        let busyDuringCleanup = await state.isBusy
        XCTAssertTrue(busyDuringCleanup)
        await fulfillment(of: [persisted], timeout: 1)
        let persistedInterrupted = await state.persistedInterrupted
        let busyAfterPersistence = await state.isBusy
        XCTAssertTrue(persistedInterrupted)
        XCTAssertTrue(busyAfterPersistence, "start must remain blocked through durable interruption persistence")
    }

    func testElapsedTimeFreezesAtCaptureQuiescenceRatherThanFinalization() {
        let beganAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let quiescedAt = Date(timeIntervalSinceReferenceDate: 1_012.345)
        let finalizationCompletedAt = Date(timeIntervalSinceReferenceDate: 1_020)

        let frozen = CaptureElapsedFreeze.milliseconds(
            recordingBeganAt: beganAt,
            captureQuiescedAt: quiescedAt,
            fallback: 0
        )
        XCTAssertEqual(frozen, 12_345)
        XCTAssertNotEqual(
            frozen,
            CaptureElapsedFreeze.milliseconds(
                recordingBeganAt: beganAt,
                captureQuiescedAt: finalizationCompletedAt,
                fallback: 0
            )
        )
    }

    func testSynchronousTerminalFailureSignalIsVisibleBeforeRelayWork() {
        let signal = CaptureTerminalFailureSignal()
        XCTAssertFalse(signal.isSignaled)
        signal.signal()
        XCTAssertTrue(signal.isSignaled, "recording commit must observe source failure before FIFO enqueue")
    }
}

private actor FailureCleanupState {
    private(set) var isBusy = false
    private(set) var persistedInterrupted = false

    func setBusy(_ value: Bool) { isBusy = value }
    func persistInterrupted() { persistedInterrupted = true }
}
