import Foundation

enum AppRecordingState: String {
    case idle
    case recording
    case processing
    case loadingModel
}

@MainActor
class AppState: ObservableObject {
    @Published var state: AppRecordingState = .idle

    var stateTitle: String {
        switch state {
        case .idle: return "🎙"
        case .recording: return "●"
        case .processing: return "⏳"
        case .loadingModel: return "⏳"
        }
    }
}
