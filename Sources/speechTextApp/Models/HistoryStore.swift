import Foundation

struct TranscriptionEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let date: Date
}

@MainActor
class HistoryStore: ObservableObject {
    @Published var entries: [TranscriptionEntry] = []

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SpeechText")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    func addEntry(_ text: String) {
        let entry = TranscriptionEntry(id: UUID(), text: text, date: Date())
        entries.insert(entry, at: 0)
        save()
    }

    func deleteEntry(_ entry: TranscriptionEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clearAll() {
        entries.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([TranscriptionEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(entries).write(to: fileURL)
    }
}
