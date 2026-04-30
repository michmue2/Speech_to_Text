import Foundation
import WhisperKit
import AVFoundation

actor TranscriberService {
    private var whisperKit: WhisperKit?
    private var activeModel: SpeechTextModel?

    /// Initialize WhisperKit with the saved model choice.
    func initialize() async throws {
        try await switchModel(to: .saved)
    }

    /// Switch to a single active WhisperKit model, unloading the previous pipeline first.
    func switchModel(to model: SpeechTextModel) async throws {
        guard activeModel != model || whisperKit == nil else { return }

        await unloadCurrentModel()

        do {
            whisperKit = try await loadWhisperKit(for: model, usingCachedFolder: true)
        } catch {
            NSLog("[TranscriberService] Cached load failed for \(model.displayName): \(error)")
            await unloadCurrentModel()
            whisperKit = try await loadWhisperKit(for: model, usingCachedFolder: false)
        }

        if let modelFolder = whisperKit?.modelFolder?.path {
            model.saveModelFolderPath(modelFolder)
        }

        activeModel = model
        NSLog("[TranscriberService] \(model.displayName) loaded and ready")
    }

    private func loadWhisperKit(for model: SpeechTextModel, usingCachedFolder: Bool) async throws -> WhisperKit {
        let modelFolder = usingCachedFolder ? model.savedModelFolderPath : nil
        let config = WhisperKitConfig(
            model: modelFolder == nil ? model.whisperKitModelName : nil,
            modelFolder: modelFolder,
            verbose: false,
            logLevel: .none,
            load: true,
            download: modelFolder == nil,
            useBackgroundDownloadSession: false
        )

        return try await WhisperKit(config)
    }

    func unloadCurrentModel() async {
        guard let whisperKit else {
            activeModel = nil
            return
        }

        await whisperKit.unloadModels()
        self.whisperKit = nil
        activeModel = nil
    }

    /// Transcribe a file path to text. Returns nil if model not loaded or no speech detected.
    func transcribeFile(path: String) async -> String? {
        guard let whisperKit = whisperKit else { return nil }

        do {
            let options = DecodingOptions(language: "en", detectLanguage: false)
            let result = try await whisperKit.transcribe(audioPath: path, decodeOptions: options, callback: nil)
            return result.first?.text
        } catch {
            print("[TranscriberService] Transcription failed: \(error)")
            return nil
        }
    }
}
