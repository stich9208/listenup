import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import CoreMedia
import ListenUpDomain

public struct CaptureApplication: Sendable, Equatable, Identifiable { public let id: String; public let name: String; public init(id: String, name: String) { self.id = id; self.name = name } }
public struct SystemAudioCaptureConfiguration: Sendable, Equatable { public var excludesCurrentProcessAudio: Bool; public var applicationID: String?; public init(excludesCurrentProcessAudio: Bool = true, applicationID: String? = nil) { self.excludesCurrentProcessAudio = excludesCurrentProcessAudio; self.applicationID = applicationID } }
public protocol SystemAudioSampleProvider: AnyObject, Sendable { var onError: (@Sendable (Error) -> Void)? { get set }; func availableApplications() async throws -> [CaptureApplication]; func start(application: CaptureApplication?, onSampleBuffer: @escaping @Sendable (CMSampleBuffer) -> Void) async throws; func stop() async throws }

/// A concrete identity lets the provider reject callbacks from an old stream.
public protocol ScreenCaptureStreamInstance: AnyObject, Sendable { var id: UUID { get }; func stop() async throws }
/// The production driver seam is exercised by ScreenCaptureProvider itself in tests.
public protocol ScreenCaptureStreamDriver: AnyObject, Sendable {
    func availableApplications() async throws -> [CaptureApplication]
    func start(application: CaptureApplication?, configuration: SystemAudioCaptureConfiguration, onSampleBuffer: @escaping @Sendable (CMSampleBuffer) -> Void, onTerminalError: @escaping @Sendable (Error) -> Void) async throws -> any ScreenCaptureStreamInstance
}
public enum ScreenCaptureAuthorization { public static func isDenied(_ error: Error) -> Bool { let value = error as NSError; return value.domain == SCStreamErrorDomain && value.code == SCStreamError.Code.userDeclined.rawValue } }

enum ScreenCaptureLifecycle: Equatable {
    case idle, starting(UUID), running(UUID), stopping(UUID)
    var token: UUID? { switch self { case .idle: nil; case let .starting(id), let .running(id), let .stopping(id): id } }
    mutating func terminalCleanup(ownedBy token: UUID) -> Bool { guard self.token == token else { return false }; self = .idle; return true }
}
private struct UnsafeSampleBuffer: @unchecked Sendable { let value: CMSampleBuffer }

public final class ScreenCaptureProvider: NSObject, SystemAudioSampleProvider, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public private(set) var configuration: SystemAudioCaptureConfiguration
    private let sampleQueue = DispatchQueue(label: "listenup.system-audio.capture")
    private let stateLock = NSLock()
    private let driver: any ScreenCaptureStreamDriver
    private var activeStream: (any ScreenCaptureStreamInstance)?
    private var sampleHandler: (@Sendable (CMSampleBuffer) -> Void)?
    private var lifecycle: ScreenCaptureLifecycle = .idle
    private var terminalBarrier: (token: UUID, barrier: ScreenCaptureTerminalBarrier)?
    private var cleanupStartedTokens = Set<UUID>()
    private var terminalError: (token: UUID, error: Error)?
    public var onError: (@Sendable (Error) -> Void)?
    public convenience init(configuration: SystemAudioCaptureConfiguration = .init()) { self.init(configuration: configuration, driver: ScreenCaptureKitStreamDriver()) }
    public init(configuration: SystemAudioCaptureConfiguration, driver: any ScreenCaptureStreamDriver) { self.configuration = configuration; self.driver = driver; super.init() }
    public func availableApplications() async throws -> [CaptureApplication] { try await driver.availableApplications() }

    /// Legacy filter API retained independently of the injectable driver.
    public func makeFilter(for application: CaptureApplication? = nil) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw ListenUpError.sourceUnavailable }
        if let application {
            guard let running = content.applications.first(where: { $0.bundleIdentifier == application.id }) else { throw ListenUpError.sourceUnavailable }
            return SCContentFilter(display: display, including: [running], exceptingWindows: [])
        }
        return SCContentFilter(display: display, excludingWindows: [])
    }

    public func start(application: CaptureApplication? = nil, onSampleBuffer: @escaping @Sendable (CMSampleBuffer) -> Void) async throws {
        let token = UUID()
        let reserved = stateLock.withLock { () -> Bool in
            guard case .idle = lifecycle else { return false }
            lifecycle = .starting(token); sampleHandler = onSampleBuffer; terminalBarrier = (token, ScreenCaptureTerminalBarrier()); terminalError = nil
            return true
        }
        guard reserved else { throw ListenUpError.writeFailed("screen capture provider is not idle") }
        do {
            let stream = try await driver.start(application: application, configuration: configuration, onSampleBuffer: { [weak self] sample in self?.deliver(sample, ownedBy: token) }, onTerminalError: { [weak self] error in self?.recordSpontaneousError(error, ownedBy: token) })
            let mustStop = stateLock.withLock { () -> Bool in
                guard case let .starting(current) = lifecycle, current == token else { return true }
                activeStream = stream; lifecycle = .running(token); return false
            }
            if mustStop { try await terminalCleanup(token: token, stream: stream); throw CancellationError() }
        } catch {
            // A failure while start is suspended has only marked terminal intent;
            // this catch is the single owner that completes its shutdown.
            try? await terminalCleanup(token: token, stream: nil)
            throw error
        }
    }

    public func stop() async throws {
        let stop = stateLock.withLock { () -> (UUID, (any ScreenCaptureStreamInstance)?, ScreenCaptureTerminalBarrier, Bool)? in
            switch lifecycle {
            case .idle: return nil
            case let .starting(token): lifecycle = .stopping(token); guard let barrier = terminalBarrier, barrier.token == token else { return nil }; return (token, nil, barrier.barrier, false)
            case let .running(token): lifecycle = .stopping(token); guard let barrier = terminalBarrier, barrier.token == token else { return nil }; return (token, activeStream, barrier.barrier, true)
            case let .stopping(token): guard let barrier = terminalBarrier, barrier.token == token else { return nil }; return (token, nil, barrier.barrier, false)
            }
        }
        guard let (token, stream, barrier, shouldClean) = stop else { return }
        if shouldClean { try? await terminalCleanup(token: token, stream: stream) }
        try await barrier.wait()
    }

    /// Legacy SCStream callback retained for callers that used the provider as
    /// an output/delegate. Driver-backed production capture uses `deliver`.
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let handler = stateLock.withLock { () -> (@Sendable (CMSampleBuffer) -> Void)? in
            guard case .running = lifecycle else { return nil }
            return sampleHandler
        }
        let forwarded = UnsafeSampleBuffer(value: sampleBuffer)
        sampleQueue.async { handler?(forwarded.value) }
    }

    /// Legacy delegate callback retained with the same terminal semantics.
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        guard let token = stateLock.withLock({ lifecycle.token }) else { return }
        recordSpontaneousError(error, ownedBy: token)
    }

    private func deliver(_ sample: CMSampleBuffer, ownedBy token: UUID) {
        guard CMSampleBufferDataIsReady(sample) else { return }
        let handler = stateLock.withLock { () -> (@Sendable (CMSampleBuffer) -> Void)? in guard case let .running(current) = lifecycle, current == token else { return nil }; return sampleHandler }
        let forwarded = UnsafeSampleBuffer(value: sample)
        sampleQueue.async { handler?(forwarded.value) }
    }
    private func recordSpontaneousError(_ error: Error, ownedBy token: UUID) {
        let state = stateLock.withLock { () -> (notify: Bool, cleanNow: Bool) in
            guard lifecycle.token == token, terminalError == nil else { return (false, false) }
            let cleanNow: Bool
            if case .running = lifecycle { cleanNow = true } else { cleanNow = false }
            lifecycle = .stopping(token); terminalError = (token, error)
            return (true, cleanNow)
        }
        // Notify App before the shared barrier completes, so explicit stop joins failure.
        if state.notify { onError?(error) }
        if state.cleanNow { Task { [weak self] in try? await self?.terminalCleanup(token: token, stream: nil) } }
    }
    private func terminalCleanup(token: UUID, stream: (any ScreenCaptureStreamInstance)?) async throws {
        let barrier = stateLock.withLock { () -> ScreenCaptureTerminalBarrier? in
            guard let barrier = terminalBarrier, barrier.token == token, cleanupStartedTokens.insert(token).inserted else { return nil }
            return barrier.barrier
        }
        guard let barrier else { if let existing = stateLock.withLock({ terminalBarrier }), existing.token == token { try await existing.barrier.wait() }; return }
        let streamToStop = stream ?? stateLock.withLock { activeStream }
        let stopError: Error?
        if let streamToStop { do { try await streamToStop.stop(); stopError = nil } catch { stopError = error } } else { stopError = nil }
        await SampleQueueQuiescer.drain(sampleQueue)
        // A driver may synchronously deliver its terminal error *during*
        // `stop()`. Read it only after stop and queue drain, immediately
        // before clearing ownership, so the shared barrier observes it.
        let spontaneousError = stateLock.withLock { () -> Error? in
            terminalError?.token == token ? terminalError?.error : nil
        }
        stateLock.withLock {
            guard lifecycle.terminalCleanup(ownedBy: token) else { return }
            activeStream = nil; sampleHandler = nil
            if terminalBarrier?.token == token { terminalBarrier = nil }; if terminalError?.token == token { terminalError = nil }; cleanupStartedTokens.remove(token)
        }
        if let spontaneousError { barrier.finish(.failure(spontaneousError)); return }
        if let stopError { barrier.finish(.failure(stopError)); throw stopError }
        barrier.finish(.success(()))
    }
}

private final class ScreenCaptureKitStreamDriver: ScreenCaptureStreamDriver, @unchecked Sendable {
    func availableApplications() async throws -> [CaptureApplication] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false); let current = Bundle.main.bundleIdentifier; var seen = Set<String>()
        return content.applications.compactMap { app in guard !app.bundleIdentifier.isEmpty, app.bundleIdentifier != current, seen.insert(app.bundleIdentifier).inserted else { return nil }; return CaptureApplication(id: app.bundleIdentifier, name: app.applicationName) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func start(application: CaptureApplication?, configuration: SystemAudioCaptureConfiguration, onSampleBuffer: @escaping @Sendable (CMSampleBuffer) -> Void, onTerminalError: @escaping @Sendable (Error) -> Void) async throws -> any ScreenCaptureStreamInstance {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false); guard let display = content.displays.first else { throw ListenUpError.sourceUnavailable }
        let filter: SCContentFilter
        if let application { guard let running = content.applications.first(where: { $0.bundleIdentifier == application.id }) else { throw ListenUpError.sourceUnavailable }; filter = SCContentFilter(display: display, including: [running], exceptingWindows: []) } else { filter = SCContentFilter(display: display, excludingWindows: []) }
        let config = SCStreamConfiguration(); config.capturesAudio = true; config.excludesCurrentProcessAudio = configuration.excludesCurrentProcessAudio; config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let instance = ScreenCaptureKitStreamInstance(filter: filter, configuration: config, onSampleBuffer: onSampleBuffer, onTerminalError: onTerminalError); try await instance.start(); return instance
    }
}
private final class ScreenCaptureKitStreamInstance: NSObject, ScreenCaptureStreamInstance, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let id = UUID(); private var stream: SCStream!; private let sampleQueue = DispatchQueue(label: "listenup.system-audio.driver"); private let onSampleBuffer: @Sendable (CMSampleBuffer) -> Void; private let onTerminalError: @Sendable (Error) -> Void
    init(filter: SCContentFilter, configuration: SCStreamConfiguration, onSampleBuffer: @escaping @Sendable (CMSampleBuffer) -> Void, onTerminalError: @escaping @Sendable (Error) -> Void) { self.onSampleBuffer = onSampleBuffer; self.onTerminalError = onTerminalError; super.init(); self.stream = SCStream(filter: filter, configuration: configuration, delegate: self) }
    func start() async throws { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue); try await stream.startCapture() }
    func stop() async throws { try await stream.stopCapture() }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) { guard type == .audio else { return }; onSampleBuffer(sampleBuffer) }
    func stream(_ stream: SCStream, didStopWithError error: any Error) { onTerminalError(error) }
}
private final class ScreenCaptureTerminalBarrier: @unchecked Sendable { private let lock = NSLock(); private var result: Result<Void, Error>?; private var waiters: [CheckedContinuation<Result<Void, Error>, Never>] = []; func wait() async throws { let result = await withCheckedContinuation { continuation in lock.withLock { if let result { continuation.resume(returning: result) } else { waiters.append(continuation) } } }; try result.get() }; func finish(_ result: Result<Void, Error>) { let waiters = lock.withLock { () -> [CheckedContinuation<Result<Void, Error>, Never>] in guard self.result == nil else { return [] }; self.result = result; let values = self.waiters; self.waiters.removeAll(); return values }; waiters.forEach { $0.resume(returning: result) } } }
enum SampleQueueQuiescer { static func drain(_ queue: DispatchQueue) async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } } }
