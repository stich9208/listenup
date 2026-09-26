import Foundation
import CoreMedia
import ScreenCaptureKit
import XCTest
@testable import ListenUpAudio

final class ScreenCaptureAuthorizationTests: XCTestCase {
    func testInjectedDriverSharesSpontaneousFailureWithConcurrentExplicitStop() async throws {
        let driver = DriverHarness(suspendStart: true)
        let provider = ScreenCaptureProvider(configuration: .init(), driver: driver)
        let errorDelivered = expectation(description: "error delivered before barrier")
        provider.onError = { _ in errorDelivered.fulfill() }
        let start = Task { try await provider.start(onSampleBuffer: { _ in }) }
        await driver.waitUntilStartEntered()
        driver.emitTerminalError(TestDriverError.spontaneous)
        await fulfillment(of: [errorDelivered], timeout: 1)
        let stop = Task { try await provider.stop() }
        driver.releaseStart()
        do { try await start.value; XCTFail("terminal suspended start cannot become running") } catch {}
        do { try await stop.value; XCTFail("explicit stop must observe spontaneous failure") } catch {}
    }

    func testInjectedErrorDuringDriverStopFailsCallbackThenSharedBarrier() async throws {
        let driver = DriverHarness()
        let provider = ScreenCaptureProvider(configuration: .init(), driver: driver)
        let callback = expectation(description: "terminal callback")
        let callbackBeforeStopReturns = CountBox()
        provider.onError = { _ in
            callbackBeforeStopReturns.increment()
            callback.fulfill()
        }
        try await provider.start(onSampleBuffer: { _ in })
        driver.injectTerminalErrorDuringStop(TestDriverError.spontaneous)

        do {
            try await provider.stop()
            XCTFail("an error injected during driver stop must fail the barrier")
        } catch {}
        await fulfillment(of: [callback], timeout: 1)
        XCTAssertEqual(callbackBeforeStopReturns.value, 1)
    }

    func testInjectedDriverRejectsStaleGenerationError() async throws {
        let driver = DriverHarness()
        let provider = ScreenCaptureProvider(configuration: .init(), driver: driver)
        let received = CountBox()
        provider.onError = { _ in received.increment() }
        try await provider.start(onSampleBuffer: { _ in })
        try await provider.stop()
        try await provider.start(onSampleBuffer: { _ in })
        driver.emitTerminalError(TestDriverError.spontaneous, at: 0)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(received.value, 0)
        try await provider.stop()
    }
    func testStaleTerminalCleanupCannotReopenNewStartOrClearItsOwnership() {
        let oldToken = UUID()
        let newToken = UUID()
        var lifecycle = ScreenCaptureLifecycle.starting(oldToken)

        // Stop owns the old reservation. Its first cleanup makes the provider
        // eligible for a new reservation while the original start remains
        // suspended in makeFilter.
        lifecycle = .stopping(oldToken)
        XCTAssertTrue(lifecycle.terminalCleanup(ownedBy: oldToken))
        XCTAssertEqual(lifecycle, .idle)

        lifecycle = .starting(newToken)
        // The old start now resumes and performs its deferred cleanup. It must
        // not clear the newer token's handler/lifecycle ownership.
        XCTAssertFalse(lifecycle.terminalCleanup(ownedBy: oldToken))
        XCTAssertEqual(lifecycle, .starting(newToken))
    }

    func testUserDeclinedIsAuthorizationDenied() {
        let error = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userDeclined.rawValue
        )

        XCTAssertTrue(ScreenCaptureAuthorization.isDenied(error))
    }

    func testOtherScreenCaptureFailureIsNotAuthorizationDenied() {
        let error = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.failedToStart.rawValue
        )

        XCTAssertFalse(ScreenCaptureAuthorization.isDenied(error))
    }

    func testUnrelatedPermissionTextIsNotAuthorizationDenied() {
        let error = NSError(
            domain: "ListenUpTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "permission denied"]
        )

        XCTAssertFalse(ScreenCaptureAuthorization.isDenied(error))
    }
}

private enum TestDriverError: Error { case spontaneous }

private final class DriverHarness: ScreenCaptureStreamDriver, @unchecked Sendable {
    private let lock = NSLock()
    private let suspendStart: Bool
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var terminalHandlers: [@Sendable (Error) -> Void] = []
    private var errorDuringStop: Error?
    init(suspendStart: Bool = false) { self.suspendStart = suspendStart }
    func availableApplications() async throws -> [CaptureApplication] { [] }
    func start(application: CaptureApplication?, configuration: SystemAudioCaptureConfiguration, onSampleBuffer: @escaping @Sendable (CMSampleBuffer) -> Void, onTerminalError: @escaping @Sendable (Error) -> Void) async throws -> any ScreenCaptureStreamInstance {
        lock.withLock { terminalHandlers.append(onTerminalError); entered = true }
        if suspendStart { await withCheckedContinuation { continuation in lock.withLock { self.continuation = continuation } } }
        return DriverStream(onStop: { [weak self] in self?.emitInjectedDuringStop(onTerminalError) })
    }
    func waitUntilStartEntered() async { while !lock.withLock({ entered }) { await Task.yield() } }
    func releaseStart() { lock.withLock { continuation?.resume(); continuation = nil } }
    func emitTerminalError(_ error: Error, at index: Int? = nil) {
        let handler = lock.withLock { index.map { terminalHandlers[$0] } ?? terminalHandlers.last }
        handler?(error)
    }
    func injectTerminalErrorDuringStop(_ error: Error) { lock.withLock { errorDuringStop = error } }
    private func emitInjectedDuringStop(_ handler: @escaping @Sendable (Error) -> Void) {
        if let error = lock.withLock({ errorDuringStop }) { handler(error) }
    }
}

private final class DriverStream: ScreenCaptureStreamInstance, @unchecked Sendable {
    let id = UUID()
    private let onStop: @Sendable () -> Void
    init(onStop: @escaping @Sendable () -> Void = {}) { self.onStop = onStop }
    func stop() async throws { onStop() }
}
private final class CountBox: @unchecked Sendable { private let lock = NSLock(); private var count = 0; func increment() { lock.withLock { count += 1 } }; var value: Int { lock.withLock { count } } }
