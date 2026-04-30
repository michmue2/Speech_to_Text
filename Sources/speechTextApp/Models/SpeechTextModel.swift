import Foundation

enum SpeechTextModel: String, CaseIterable, Sendable {
    case tiny
    case distilWhisperV3

    private static let defaultsKey = "SpeechText.SelectedModel"
    private static let modelFolderPrefix = "SpeechText.ModelFolder."

    var displayName: String {
        switch self {
        case .tiny:
            return "Tiny"
        case .distilWhisperV3:
            return "Distil-Whisper-v3"
        }
    }

    var menuTitle: String {
        switch self {
        case .tiny:
            return "Tiny"
        case .distilWhisperV3:
            return "Distil-Whisper-v3"
        }
    }

    var statusLabel: String {
        switch self {
        case .tiny:
            return "Tiny"
        case .distilWhisperV3:
            return "Distil"
        }
    }

    var whisperKitModelName: String {
        switch self {
        case .tiny:
            return "openai_whisper-tiny"
        case .distilWhisperV3:
            return "distil-whisper_distil-large-v3_594MB"
        }
    }

    static var saved: SpeechTextModel {
        guard
            let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
            let model = SpeechTextModel(rawValue: rawValue)
        else {
            return .tiny
        }

        return model
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }

    var savedModelFolderPath: String? {
        let key = Self.modelFolderPrefix + rawValue
        guard let path = UserDefaults.standard.string(forKey: key) else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        return path
    }

    func saveModelFolderPath(_ path: String) {
        let key = Self.modelFolderPrefix + rawValue
        UserDefaults.standard.set(path, forKey: key)
    }
}
