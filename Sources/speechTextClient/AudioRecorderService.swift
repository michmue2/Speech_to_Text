import Foundation
import AVFoundation

actor AudioRecorderService {
    private var audioEngine: AVAudioEngine?
    private var collectedBuffers: [AVAudioPCMBuffer] = []
    private var isRecording: Bool = false
    private var maxDuration: TimeInterval = 30
    private var recordingTimer: DispatchWorkItem?

    /// Start recording audio. Returns false if already recording.
    func start() async -> Bool {
        guard !isRecording else { return false }
        isRecording = true
        collectedBuffers.removeAll()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)!

        let actorRef = self
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            var newBufferAvailable = true
            let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(targetFormat.sampleRate * Double(buffer.frameLength) / targetFormat.sampleRate)
            )!

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { inBufferPointer, outStatus in
                if newBufferAvailable {
                    newBufferAvailable = false
                    outStatus.pointee = .haveData
                    return buffer
                } else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }

            if error == nil && convertedBuffer.frameLength > 0 {
                Task { await actorRef.collectBuffer(convertedBuffer) }
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("[AudioRecorderService] Failed to start engine: \(error)")
            isRecording = false
            return false
        }

        audioEngine = engine

        // Auto-stop timer
        let workItem = DispatchWorkItem {
            Task { await actorRef.stop() }
        }
        recordingTimer = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + maxDuration, execute: workItem)

        return true
    }

    /// Collect a buffer for later combination
    nonisolated func collectBuffer(_ buffer: AVAudioPCMBuffer) async {
        await self.doCollect(buffer)
    }

    private func doCollect(_ buffer: AVAudioPCMBuffer) {
        collectedBuffers.append(buffer)
    }

    /// Stop recording and return the combined buffer. Nil if not recording.
    func stop() async -> AVAudioPCMBuffer? {
        isRecording = false
        recordingTimer?.cancel()
        recordingTimer = nil
        let buffers = collectedBuffers
        let result = combineBuffers(buffers)
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        collectedBuffers.removeAll()
        return result
    }

    /// Combine multiple PCM buffers into a single buffer
    private func combineBuffers(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard !buffers.isEmpty else { return nil }
        guard let format = buffers.first?.format else { return nil }

        let totalFrames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard totalFrames > 0 else { return nil }

        let combined = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames))!

        var frameOffset = 0
        for buffer in buffers {
            let frames = Int(buffer.frameLength)
            if format.channelCount == 1 {
                let srcBuffer = buffer.floatChannelData![0]
                let dstBuffer = combined.floatChannelData![0]
                for i in 0..<frames {
                    dstBuffer[frameOffset + i] = srcBuffer[i]
                }
            }
            frameOffset += frames
        }
        combined.frameLength = AVAudioFrameCount(totalFrames)
        return combined
    }
}
