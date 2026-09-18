import AVFoundation
import XCTest
@testable import ListenUpAudio

final class AudioLevelMeteringTests: XCTestCase {
    func testSilenceProducesZeroLevel() throws {
        let buffer = try makeBuffer(amplitude: 0)
        XCTAssertEqual(AudioLevelMetering.normalizedLevel(in: buffer), 0)
    }

    func testAudibleSignalProducesVisibleLevel() throws {
        let buffer = try makeBuffer(amplitude: 0.25)
        let level = AudioLevelMetering.normalizedLevel(in: buffer)
        XCTAssertGreaterThan(level, 0.7)
        XCTAssertLessThanOrEqual(level, 1)
    }

    private func makeBuffer(amplitude: Float) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480) else {
            throw NSError(domain: "AudioLevelMeteringTests", code: 1)
        }
        buffer.frameLength = 480
        guard let channel = buffer.floatChannelData?[0] else {
            throw NSError(domain: "AudioLevelMeteringTests", code: 2)
        }
        for index in 0..<Int(buffer.frameLength) {
            channel[index] = index.isMultiple(of: 2) ? amplitude : -amplitude
        }
        return buffer
    }
}
