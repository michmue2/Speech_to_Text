import Foundation
import WhisperKit
import AVFoundation

actor TranscriberService {
    private var whisperKit: WhisperKit?
    private var modelLoaded: Bool = false
    private var warmingUp: Bool = false

    /// Initialize WhisperKit: downloads model if needed, then fully loads it
    func initialize() async throws {
        guard !modelLoaded && !warmingUp else { return }
        warmingUp = true

        let config = WhisperKitConfig(model: "tiny", verbose: false, logLevel: .none, useBackgroundDownloadSession: false)
        whisperKit = try await WhisperKit(config)
        modelLoaded = true
        warmingUp = false
        NSLog("[TranscriberService] Model loaded and ready")
    }

    /// Transcribe a file path to text. Returns nil if model not loaded or no speech detected.
    func transcribeFile(path: String) async -> String? {
        guard let whisperKit = whisperKit else { return nil }

        do {
            let result = try await whisperKit.transcribe(audioPath: path, callback: nil)
            return result.first?.text
        } catch {
            print("[TranscriberService] Transcription failed: \(error)")
            return nil
        }
    }
}
