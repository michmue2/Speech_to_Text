import ApplicationServices
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var appState: AppState!
    var keyListener: GlobalKeyListenerService!
    var audioRecorder: AudioRecorderService!
    var transcriber: TranscriberService!
    var historyStore: HistoryStore!
    var historyWindow: HistoryWindow?
    var selectedModel: SpeechTextModel = .saved
    let textInjector = TextInjectorService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()
        audioRecorder = AudioRecorderService()
        transcriber = TranscriberService()
        historyStore = HistoryStore()

        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusTitle()
        statusItem.menu = buildMenu()

        Task {
            await loadModel(selectedModel, restorePreviousOnFailure: false)
        }

        keyListener = GlobalKeyListenerService()
        keyListener.onDown = { [weak self] in
            Task { await self?.handleKeyDown() }
        }
        keyListener.onUp = { [weak self] in
            Task { await self?.handleKeyUp() }
        }
        keyListener.start()
    }

    @MainActor func handleKeyDown() async {
        guard appState.state == .idle else { return }
        appState.state = .recording
        updateStatusTitle()
        let started = await audioRecorder.start()
        if !started {
            appState.state = .idle
            updateStatusTitle()
        }
    }

    @MainActor func handleKeyUp() async {
        guard appState.state == .recording else { return }
        appState.state = .processing
        updateStatusTitle()
        let chunks = await audioRecorder.stop()
        guard !chunks.isEmpty else {
            appState.state = .idle
            updateStatusTitle()
            return
        }

        do {
            var transcripts: [String] = []

            for chunk in chunks.sorted(by: { $0.index < $1.index }) {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("speechtext_recording_\(UUID().uuidString)_\(chunk.index).wav")
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try AudioRecorderService.writeBufferToWAV(chunk.buffer, to: tempURL)
                let transcript = await transcriber.transcribeFile(path: tempURL.path)

                if let transcript, !transcript.isEmpty {
                    transcripts.append(transcript)
                }
            }

            let transcript = mergeTranscripts(transcripts)
            guard !transcript.isEmpty else {
                appState.state = .idle
                updateStatusTitle()
                return
            }
            // Save to history
            historyStore.addEntry(transcript)
            // Inject text
            textInjector.inject(transcript)
            appState.state = .idle
            updateStatusTitle()
        } catch {
            NSLog("[App] WAV conversion failed: \(error)")
            showNotification(title: "SpeechText Error", message: "Failed to process audio recording.")
            appState.state = .idle
            updateStatusTitle()
        }
    }

    func mergeTranscripts(_ transcripts: [String]) -> String {
        var mergedWords: [String] = []

        for transcript in transcripts {
            let words = transcript.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !words.isEmpty else { continue }

            let overlap = overlapWordCount(existing: mergedWords, next: words)
            if !mergedWords.isEmpty {
                mergedWords.append("[]")
            }
            mergedWords.append(contentsOf: words.dropFirst(overlap))
        }

        return mergedWords.joined(separator: " ")
    }

    func overlapWordCount(existing: [String], next: [String]) -> Int {
        let maxOverlap = min(15, existing.count, next.count)
        guard maxOverlap > 0 else { return 0 }

        for count in stride(from: maxOverlap, through: 1, by: -1) {
            let suffix = existing.suffix(count).map(normalizedWord)
            let prefix = next.prefix(count).map(normalizedWord)
            if suffix == prefix {
                return count
            }
        }

        return 0
    }

    func normalizedWord(_ word: String) -> String {
        let scalars = word.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Active • \(selectedModel.displayName)", action: nil, keyEquivalent: ""))
        menu.addItem(modelMenuItem())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "History", action: #selector(showHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    func modelMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        for model in SpeechTextModel.allCases {
            let modelItem = NSMenuItem(title: model.menuTitle, action: #selector(selectModel(_:)), keyEquivalent: "")
            modelItem.target = self
            modelItem.representedObject = model.rawValue
            modelItem.state = model == selectedModel ? .on : .off
            submenu.addItem(modelItem)
        }

        item.submenu = submenu
        return item
    }

    @MainActor func updateStatusTitle() {
        statusItem.button?.title = "\(appState.stateTitle) \(selectedModel.statusLabel)"
    }

    @MainActor func refreshMenu() {
        statusItem.menu = buildMenu()
    }

    @MainActor func loadModel(_ model: SpeechTextModel, restorePreviousOnFailure: Bool) async {
        guard appState.state == .idle || appState.state == .loadingModel else { return }

        let previousModel = selectedModel
        selectedModel = model
        appState.state = .loadingModel
        updateStatusTitle()
        refreshMenu()

        do {
            try await transcriber.switchModel(to: model)
            model.save()
            appState.state = .idle
            updateStatusTitle()
            refreshMenu()
            NSLog("[App] WhisperKit initialized with \(model.displayName)")
        } catch {
            NSLog("[App] Failed to initialize \(model.displayName): \(error)")
            showModelLoadError(model: model)

            guard restorePreviousOnFailure, previousModel != model else {
                appState.state = .idle
                updateStatusTitle()
                refreshMenu()
                return
            }

            selectedModel = previousModel
            updateStatusTitle()
            refreshMenu()

            do {
                try await transcriber.switchModel(to: previousModel)
                previousModel.save()
            } catch {
                NSLog("[App] Failed to restore \(previousModel.displayName): \(error)")
                showModelLoadError(model: previousModel)
            }

            appState.state = .idle
            updateStatusTitle()
            refreshMenu()
        }
    }

    @MainActor @objc func selectModel(_ sender: NSMenuItem) {
        guard
            appState.state == .idle,
            let rawValue = sender.representedObject as? String,
            let model = SpeechTextModel(rawValue: rawValue),
            model != selectedModel
        else {
            return
        }

        Task {
            await loadModel(model, restorePreviousOnFailure: true)
        }
    }

    @objc func showHistory() {
        if let historyWindow = historyWindow, historyWindow.isVisible {
            historyWindow.close()
        } else {
            if self.historyWindow == nil {
                self.historyWindow = HistoryWindow(store: historyStore)
            }
            self.historyWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "SpeechText"
        alert.informativeText = "Dictate with the right Option (⌥) key.\nRuns locally with WhisperKit.\nCurrent model: \(selectedModel.displayName)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    @MainActor func showModelLoadError(model: SpeechTextModel) {
        let alert = NSAlert()
        alert.messageText = "SpeechText"
        alert.informativeText = "Failed to load \(model.displayName). Check your internet connection and try again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func showNotification(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        NSUserNotificationCenter.default.deliver(notification)
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
