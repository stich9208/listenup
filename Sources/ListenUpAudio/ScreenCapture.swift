import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import CoreMedia
import ListenUpDomain

public struct CaptureApplication: Sendable, Equatable, Identifiable { public let id: String; public let name: String; public init(id: String, name: String) { self.id = id; self.name = name } }

public struct SystemAudioCaptureConfiguration: Sendable, Equatable {
    public var excludesCurrentProcessAudio: Bool
    public var applicationID: String?
    public init(excludesCurrentProcessAudio: Bool = true, applicationID: String? = nil) { self.excludesCurrentProcessAudio = excludesCurrentProcessAudio; self.applicationID = applicationID }
}

public final class ScreenCaptureProvider: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public private(set) var configuration: SystemAudioCaptureConfiguration
    private let sampleQueue = DispatchQueue(label: "listenup.system-audio.capture")
    private var activeStream: SCStream?
    private var sampleHandler: (@Sendable (CMSampleBuffer) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?
    public init(configuration: SystemAudioCaptureConfiguration = .init()) { self.configuration = configuration; super.init() }
    public func availableApplications() async throws -> [CaptureApplication] { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).applications.map { CaptureApplication(id: $0.bundleIdentifier, name: $0.applicationName) } }
    public func makeFilter(for application: CaptureApplication? = nil) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw ListenUpError.sourceUnavailable }
        if let requested = application {
            guard let running = content.applications.first(where: { $0.bundleIdentifier == requested.id }) else { throw ListenUpError.sourceUnavailable }
            return SCContentFilter(display: display, including: [running], exceptingWindows: [])
        }
        return SCContentFilter(display: display, excludingWindows: [])
    }
    public func start(application: CaptureApplication? = nil, onSampleBuffer: @escaping @Sendable (CMSampleBuffer) -> Void) async throws {
        guard activeStream == nil else { return }
        let filter = try await makeFilter(for: application)
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.capturesAudio = true
        streamConfiguration.excludesCurrentProcessAudio = configuration.excludesCurrentProcessAudio
        streamConfiguration.width = 2; streamConfiguration.height = 2
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        self.sampleHandler = onSampleBuffer
        do { try await stream.startCapture(); activeStream = stream }
        catch { self.sampleHandler = nil; throw error }
    }
    public func stop() async throws {
        guard let stream = activeStream else { return }
        try await stream.stopCapture()
        activeStream = nil; sampleHandler = nil
    }
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        sampleHandler?(sampleBuffer)
    }
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        activeStream = nil
        sampleHandler = nil
        onError?(error)
    }
}
