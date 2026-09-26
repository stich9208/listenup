import Foundation

/// A provider can report a terminal stop error only after it has quiesced its
/// delivery queue.  Retaining that instant lets callers freeze elapsed time
/// correctly even on an interrupted recording.
public struct SystemAudioRecorderStopError: Error, @unchecked Sendable {
    public let captureQuiescedAt: Date
    public let underlyingError: Error

    public init(captureQuiescedAt: Date, underlyingError: Error) {
        self.captureQuiescedAt = captureQuiescedAt
        self.underlyingError = underlyingError
    }
}
