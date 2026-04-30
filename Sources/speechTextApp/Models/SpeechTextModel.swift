import Foundation

enum SpeechTextModel: String, CaseIterable, Sendable {
    case tiny
    case distilWhisperV3

    private static let defaultsKey = "SpeechText.SelectedModel"

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
}
