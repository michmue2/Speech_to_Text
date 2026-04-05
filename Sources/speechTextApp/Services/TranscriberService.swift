import Foundation
import WhisperKit
import AVFoundation

actor TranscriberService {
    private var whisperKit: WhisperKit?
    private var isModelLoaded: Bool = false

    /// Initialize WhisperKit, downloading the model if needed.
    func initialize() async throws {
        guard !isModelLoaded else { return }
        whisperKit = try await WhisperKit()
        isModelLoaded = true
    }

    /// Transcribe a file path to text. Returns nil if model not loaded or no speech detected.
    func transcribeFile(path: String) async -> String? {
        guard let whisperKit = whisperKit else { return nil }

        do {
            let result = try await whisperKit.transcribe(audioPath: path)
            return result.first?.text
        } catch {
            print("[TranscriberService] Transcription failed: \(error)")
            return nil
        }
    }
}
