import AVFoundation
import CoreMedia
import Foundation

enum AudioLevelMetering {
    /// Maps RMS amplitude from -60...0 dBFS into a stable 0...1 meter value.
    static func normalizedLevel(in buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return 0 }

        var sumOfSquares = 0.0
        var sampleCount = 0

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channels = buffer.floatChannelData else { return 0 }
            accumulate(
                channels: channels,
                frameCount: frameCount,
                channelCount: channelCount,
                interleaved: buffer.format.isInterleaved,
                sumOfSquares: &sumOfSquares,
                sampleCount: &sampleCount
            )
        case .pcmFormatFloat64:
            return 0
        case .pcmFormatInt16:
            guard let channels = buffer.int16ChannelData else { return 0 }
            accumulateIntegers(
                channels: channels,
                frameCount: frameCount,
                channelCount: channelCount,
                interleaved: buffer.format.isInterleaved,
                scale: Double(Int16.max),
                sumOfSquares: &sumOfSquares,
                sampleCount: &sampleCount
            )
        case .pcmFormatInt32:
            guard let channels = buffer.int32ChannelData else { return 0 }
            accumulateIntegers(
                channels: channels,
                frameCount: frameCount,
                channelCount: channelCount,
                interleaved: buffer.format.isInterleaved,
                scale: Double(Int32.max),
                sumOfSquares: &sumOfSquares,
                sampleCount: &sampleCount
            )
        case .otherFormat:
            return 0
        @unknown default:
            return 0
        }

        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sumOfSquares / Double(sampleCount))
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return Float(min(1, max(0, (decibels + 60) / 60)))
    }

    static func normalizedLevel(in sampleBuffer: CMSampleBuffer) -> Float {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription)
        else { return 0 }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return 0 }

        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return 0 }
        return normalizedLevel(in: buffer)
    }

    private static func accumulate<T: BinaryFloatingPoint>(
        channels: UnsafePointer<UnsafeMutablePointer<T>>,
        frameCount: Int,
        channelCount: Int,
        interleaved: Bool,
        sumOfSquares: inout Double,
        sampleCount: inout Int
    ) {
        let buffers = interleaved ? 1 : channelCount
        let valuesPerBuffer = interleaved ? frameCount * channelCount : frameCount
        for channel in 0..<buffers {
            for frame in 0..<valuesPerBuffer {
                let value = Double(channels[channel][frame])
                guard value.isFinite else { continue }
                sumOfSquares += value * value
                sampleCount += 1
            }
        }
    }

    private static func accumulateIntegers<T: FixedWidthInteger>(
        channels: UnsafePointer<UnsafeMutablePointer<T>>,
        frameCount: Int,
        channelCount: Int,
        interleaved: Bool,
        scale: Double,
        sumOfSquares: inout Double,
        sampleCount: inout Int
    ) {
        let buffers = interleaved ? 1 : channelCount
        let valuesPerBuffer = interleaved ? frameCount * channelCount : frameCount
        for channel in 0..<buffers {
            for frame in 0..<valuesPerBuffer {
                let value = Double(Int64(channels[channel][frame])) / scale
                sumOfSquares += value * value
                sampleCount += 1
            }
        }
    }
}
