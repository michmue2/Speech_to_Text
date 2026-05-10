import Foundation
import AVFoundation

struct AudioRecordingChunk {
    let index: Int
    let buffer: AVAudioPCMBuffer
}

struct AudioRecordingResult {
    let fullBuffer: AVAudioPCMBuffer
    let fallbackChunks: [AudioRecordingChunk]

    var duration: TimeInterval {
        Double(fullBuffer.frameLength) / fullBuffer.format.sampleRate
    }
}

actor AudioRecorderService {
    private var audioEngine: AVAudioEngine?
    private var fullRecordingBuffers: [AVAudioPCMBuffer] = []
    private var collectedBuffers: [AVAudioPCMBuffer] = []
    private var completedChunks: [AudioRecordingChunk] = []
    private var isRecording: Bool = false
    private let chunkDuration: TimeInterval = 30
    private let overlapDuration: TimeInterval = 1
    private var chunkTimer: DispatchWorkItem?
    private var nextChunkIndex: Int = 0
    private var framesSinceLastChunk: AVAudioFramePosition = 0

    /// Start recording audio. Returns false if already recording.
    func start() async -> Bool {
        guard !isRecording else { return false }
        isRecording = true
        fullRecordingBuffers.removeAll()
        collectedBuffers.removeAll()
        completedChunks.removeAll()
        nextChunkIndex = 0
        framesSinceLastChunk = 0

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

        scheduleChunkTimer()

        return true
    }

    /// Collect a buffer for later combination
    nonisolated func collectBuffer(_ buffer: AVAudioPCMBuffer) async {
        await self.doCollect(buffer)
    }

    private func doCollect(_ buffer: AVAudioPCMBuffer) {
        guard isRecording else { return }
        fullRecordingBuffers.append(buffer)
        collectedBuffers.append(buffer)
        framesSinceLastChunk += AVAudioFramePosition(buffer.frameLength)
    }

    /// Stop recording and return one canonical full buffer plus internal chunks for fallback transcription.
    func stop() async -> AudioRecordingResult? {
        guard isRecording else { return nil }
        isRecording = false
        chunkTimer?.cancel()
        chunkTimer = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        if framesSinceLastChunk > 0, let finalBuffer = combineBuffers(collectedBuffers) {
            completedChunks.append(AudioRecordingChunk(index: nextChunkIndex, buffer: finalBuffer))
            nextChunkIndex += 1
        }

        guard let fullBuffer = combineBuffers(fullRecordingBuffers) else {
            fullRecordingBuffers.removeAll()
            collectedBuffers.removeAll()
            completedChunks.removeAll()
            framesSinceLastChunk = 0
            return nil
        }

        let chunks = completedChunks
        fullRecordingBuffers.removeAll()
        collectedBuffers.removeAll()
        completedChunks.removeAll()
        framesSinceLastChunk = 0
        return AudioRecordingResult(fullBuffer: fullBuffer, fallbackChunks: chunks)
    }

    private func scheduleChunkTimer() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self.flushCurrentChunk() }
        }
        chunkTimer = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + chunkDuration, execute: workItem)
    }

    private func flushCurrentChunk() {
        guard isRecording else { return }
        defer { scheduleChunkTimer() }

        guard framesSinceLastChunk > 0, let chunkBuffer = combineBuffers(collectedBuffers) else {
            return
        }

        completedChunks.append(AudioRecordingChunk(index: nextChunkIndex, buffer: chunkBuffer))
        nextChunkIndex += 1

        if let overlapBuffer = tailBuffer(from: chunkBuffer, duration: overlapDuration) {
            collectedBuffers = [overlapBuffer]
        } else {
            collectedBuffers.removeAll()
        }
        framesSinceLastChunk = 0
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

    private func tailBuffer(from buffer: AVAudioPCMBuffer, duration: TimeInterval) -> AVAudioPCMBuffer? {
        let framesToCopy = min(
            Int(buffer.frameLength),
            Int(buffer.format.sampleRate * duration)
        )
        guard framesToCopy > 0 else { return nil }

        let tail = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: AVAudioFrameCount(framesToCopy)
        )!

        if buffer.format.channelCount == 1 {
            let srcStart = Int(buffer.frameLength) - framesToCopy
            let srcBuffer = buffer.floatChannelData![0].advanced(by: srcStart)
            let dstBuffer = tail.floatChannelData![0]
            dstBuffer.update(from: srcBuffer, count: framesToCopy)
        }

        tail.frameLength = AVAudioFrameCount(framesToCopy)
        return tail
    }
}
