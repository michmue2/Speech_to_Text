import Foundation
import AVFoundation

extension AudioRecorderService {
    /// Write PCM buffer to WAV file at the given URL
    static func writeBufferToWAV(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: buffer.format.sampleRate,
                AVNumberOfChannelsKey: buffer.format.channelCount,
            ]
        )

        // If buffer format doesn't match, convert
        if buffer.format.commonFormat != .pcmFormatInt16 {
            let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: buffer.format.sampleRate,
                                              channels: buffer.format.channelCount,
                                              interleaved: true)!
            let converter = AVAudioConverter(from: buffer.format, to: targetFormat)!
            let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                   frameCapacity: buffer.frameCapacity)!
            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if let error = error { throw error }
            try audioFile.write(from: convertedBuffer)
        } else {
            try audioFile.write(from: buffer)
        }
    }
}
