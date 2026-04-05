import Foundation
import AVFoundation

extension AudioRecorderService {
    /// Write PCM buffer to WAV file at the given URL
    static func writeBufferToWAV(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        // Ensure format matches what AVAudioFile expects
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 16000.0,
                                          channels: 1,
                                          interleaved: false)!
        let fileSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !targetFormat.isInterleaved,
        ]

        // Delete existing file if any
        try? FileManager.default.removeItem(at: url)

        let audioFile = try AVAudioFile(forWriting: url, settings: fileSettings)

        // Convert to target format if needed
        if buffer.format.commonFormat != .pcmFormatFloat32 ||
           buffer.format.sampleRate != 16000.0 ||
           buffer.format.channelCount != 1 {
            let converter = AVAudioConverter(from: buffer.format, to: targetFormat)!
            let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                   frameCapacity: buffer.frameCapacity * 2)!
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
