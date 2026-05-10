import ApplicationServices
import AppKit
import AVFoundation

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
    let singleFileTranscriptionLimit: TimeInterval = 4 * 60

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
        guard let recording = await audioRecorder.stop() else {
            appState.state = .idle
            updateStatusTitle()
            return
        }

        do {
            let transcript = TranscriptCleaner.clean(try await transcribeRecording(recording))
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

    private func transcribeRecording(_ recording: AudioRecordingResult) async throws -> String {
        var singleFileCandidate: String?

        if recording.duration <= singleFileTranscriptionLimit {
            let transcript = try await transcribeBuffer(recording.fullBuffer, fileLabel: "full")
            if isUsableSingleFileTranscript(transcript, duration: recording.duration) {
                return transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }

            singleFileCandidate = transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("[App] Single-file transcription was empty or suspiciously short. Falling back to chunk transcription.")
        } else {
            NSLog("[App] Recording is longer than \(Int(singleFileTranscriptionLimit))s. Using chunk fallback.")
        }

        let fallbackTranscript = try await transcribeChunks(recording.fallbackChunks)
        if !fallbackTranscript.isEmpty {
            return fallbackTranscript
        }

        return singleFileCandidate ?? ""
    }

    private func transcribeBuffer(_ buffer: AVAudioPCMBuffer, fileLabel: String) async throws -> String? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechtext_recording_\(UUID().uuidString)_\(fileLabel).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try AudioRecorderService.writeBufferToWAV(buffer, to: tempURL)
        return await transcriber.transcribeFile(path: tempURL.path)
    }

    private func transcribeChunks(_ chunks: [AudioRecordingChunk]) async throws -> String {
        var transcripts: [String] = []

        for chunk in chunks.sorted(by: { $0.index < $1.index }) {
            let transcript = try await transcribeBuffer(chunk.buffer, fileLabel: "chunk_\(chunk.index)")
            if let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                transcripts.append(transcript)
            }
        }

        return TranscriptStitcher.merge(transcripts)
    }

    private func isUsableSingleFileTranscript(_ transcript: String?, duration: TimeInterval) -> Bool {
        guard let transcript = transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
              !transcript.isEmpty
        else {
            return false
        }

        if duration >= 60 {
            return wordCount(in: transcript) > 2
        }

        return true
    }

    private func wordCount(in text: String) -> Int {
        text.split { character in
            !character.isLetter && !character.isNumber && character != "'" && character != "’"
        }.count
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
