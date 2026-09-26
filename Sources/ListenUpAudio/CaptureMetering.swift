import Foundation

/// Decides whether a capture callback may do the relatively expensive level
/// calculation.  It is deliberately independent of the UI so it is usable on
/// the microphone and ScreenCaptureKit queues and deterministic in tests.
final class CaptureMeteringGate: @unchecked Sendable {
    static let intervalNanoseconds: UInt64 = 100_000_000

    private let lock = NSLock()
    private var lastMeasurementNanoseconds: UInt64?

    func shouldMeasure(at nanoseconds: UInt64) -> Bool {
        lock.withLock {
            guard let lastMeasurementNanoseconds else {
                self.lastMeasurementNanoseconds = nanoseconds
                return true
            }
            guard nanoseconds >= lastMeasurementNanoseconds + Self.intervalNanoseconds else { return false }
            self.lastMeasurementNanoseconds = nanoseconds
            return true
        }
    }

    func reset() { lock.withLock { lastMeasurementNanoseconds = nil } }
}

public enum CaptureMeterSource: Sendable {
    case microphone
    case systemAudio
}

public struct CaptureMeterSnapshot: Sendable, Equatable {
    public let microphoneLevel: Float
    public let systemAudioLevel: Float
    public let microphonePeak: Float
    public let systemAudioPeak: Float

    public init(microphoneLevel: Float, systemAudioLevel: Float, microphonePeak: Float, systemAudioPeak: Float) {
        self.microphoneLevel = microphoneLevel
        self.systemAudioLevel = systemAudioLevel
        self.microphonePeak = microphonePeak
        self.systemAudioPeak = systemAudioPeak
    }
}

/// Retains source peaks without involving the MainActor.  Its callback is
/// invoked at most ten times per second while active, and never while inactive.
public final class CaptureMeterRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var lastPublicationNanoseconds: UInt64?
    private var microphoneLevel: Float = 0
    private var systemAudioLevel: Float = 0
    private var microphonePeak: Float = 0
    private var systemAudioPeak: Float = 0
    public var onSnapshot: (@Sendable (CaptureMeterSnapshot) -> Void)?

    public init() {}

    public func resetForNewRecording() {
        lock.withLock {
            lastPublicationNanoseconds = nil
            microphoneLevel = 0
            systemAudioLevel = 0
            microphonePeak = 0
            systemAudioPeak = 0
        }
    }

    public func record(_ level: Float, from source: CaptureMeterSource, at nanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        // Invoke while holding the state lock. This is intentionally a tiny
        // callback (the production client only schedules MainActor work), and
        // it closes the otherwise unavoidable selected-callback race: once
        // setActive(false) has acquired and released this lock, no prior
        // record call can still begin an onSnapshot invocation.
        lock.withLock {
            switch source {
            case .microphone:
                microphoneLevel = level
                microphonePeak = max(microphonePeak, level)
            case .systemAudio:
                systemAudioLevel = level
                systemAudioPeak = max(systemAudioPeak, level)
            }
            guard active,
                  lastPublicationNanoseconds == nil || nanoseconds >= lastPublicationNanoseconds! + CaptureMeteringGate.intervalNanoseconds
            else { return }
            lastPublicationNanoseconds = nanoseconds
            let snapshot = CaptureMeterSnapshot(
                microphoneLevel: microphoneLevel,
                systemAudioLevel: systemAudioLevel,
                microphonePeak: microphonePeak,
                systemAudioPeak: systemAudioPeak
            )
            onSnapshot?(snapshot)
        }
    }

    public func setActive(_ active: Bool, at nanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.withLock {
            self.active = active
            guard active else { return }
            lastPublicationNanoseconds = nanoseconds
            let snapshot = CaptureMeterSnapshot(
                microphoneLevel: microphoneLevel,
                systemAudioLevel: systemAudioLevel,
                microphonePeak: microphonePeak,
                systemAudioPeak: systemAudioPeak
            )
            onSnapshot?(snapshot)
        }
    }

    public func snapshot() -> CaptureMeterSnapshot {
        lock.withLock {
            CaptureMeterSnapshot(
                microphoneLevel: microphoneLevel,
                systemAudioLevel: systemAudioLevel,
                microphonePeak: microphonePeak,
                systemAudioPeak: systemAudioPeak
            )
        }
    }
}

/// Reorders asynchronous finalization callbacks without making capture
/// callbacks wait for disk finalization.
final class OrderedFinalizer<Value: Sendable>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "listenup.system-audio.finalization")
    private var nextSequence = 0
    private var completed: [Int: Value] = [:]

    /// A finalizer belongs to one recorder run.  Callers must only reset it
    /// after every submitted completion has been delivered.
    func resetAfterDraining() { queue.sync { nextSequence = 0; completed.removeAll() } }

    func complete(sequence: Int, value: Value, deliver: @escaping @Sendable (Value) -> Void) {
        queue.async {
            self.completed[sequence] = value
            while let next = self.completed.removeValue(forKey: self.nextSequence) {
                self.nextSequence += 1
                deliver(next)
            }
        }
    }
}

/// A FIFO handoff from capture/finalization queues to one application-side
/// consumer.  A callback only appends work; it never waits for MainActor or
/// storage. `drain()` acknowledges every accepted event, including events
/// submitted immediately before a stop barrier.
public final class FinalizedEventRelay<Event: Sendable>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "listenup.finalized-event-relay")
    private var events: [Event] = []
    private var consumerScheduled = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func submit(_ event: Event, startConsumer: @escaping @Sendable () -> Void) {
        queue.async {
            self.events.append(event)
            guard !self.consumerScheduled else { return }
            self.consumerScheduled = true
            startConsumer()
        }
    }

    public func next() -> Event? {
        queue.sync {
            guard !events.isEmpty else { return nil }
            return events.removeFirst()
        }
    }

    /// Returns whether the sole consumer should continue its current FIFO run.
    @discardableResult
    public func acknowledgeOne() -> Bool {
        queue.sync {
            if !events.isEmpty { return true }
            consumerScheduled = false
            let waiters = drainWaiters
            drainWaiters.removeAll()
            waiters.forEach { $0.resume() }
            return false
        }
    }

    /// Waits until the consumer has acknowledged each event accepted before
    /// this barrier. Capture must be quiesced before calling this method.
    public func drain() async {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.consumerScheduled || !self.events.isEmpty else {
                    continuation.resume()
                    return
                }
                self.drainWaiters.append(continuation)
            }
        }
    }
}
