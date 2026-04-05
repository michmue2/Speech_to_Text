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
    let textInjector = TextInjectorService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()
        audioRecorder = AudioRecorderService()
        transcriber = TranscriberService()
        historyStore = HistoryStore()

        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙"
        statusItem.menu = buildMenu()

        Task {
            do {
                try await transcriber.initialize()
                NSLog("[App] WhisperKit initialized")
            } catch {
                NSLog("[App] Failed to initialize WhisperKit: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.showModelLoadError()
                }
            }
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
        statusItem.button?.title = "●"
        let started = await audioRecorder.start()
        if !started {
            appState.state = .idle
            statusItem.button?.title = "🎙"
        }
    }

    @MainActor func handleKeyUp() async {
        guard appState.state == .recording else { return }
        appState.state = .processing
        statusItem.button?.title = "⏳"
        let buffer = await audioRecorder.stop()
        guard let buffer = buffer else {
            appState.state = .idle
            statusItem.button?.title = "🎙"
            return
        }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("speechtext_recording.wav")
        do {
            try AudioRecorderService.writeBufferToWAV(buffer, to: tempURL)
            let transcript = await transcriber.transcribeFile(path: tempURL.path)
            try? FileManager.default.removeItem(at: tempURL)
            guard let transcript = transcript, !transcript.isEmpty else {
                appState.state = .idle
                statusItem.button?.title = "🎙"
                return
            }
            // Save to history
            historyStore.addEntry(transcript)
            // Inject text
            textInjector.inject(transcript)
            appState.state = .idle
            statusItem.button?.title = "🎙"
        } catch {
            NSLog("[App] WAV conversion failed: \(error)")
            showNotification(title: "SpeechText Error", message: "Failed to process audio recording.")
            appState.state = .idle
            statusItem.button?.title = "🎙"
        }
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Active", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "History", action: #selector(showHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        return menu
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
        alert.informativeText = "Dictate with the right Option (⌥) key.\nRuns locally with WhisperKit."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    @MainActor func showModelLoadError() {
        let alert = NSAlert()
        alert.messageText = "SpeechText"
        alert.informativeText = "Failed to load WhisperKit model. Check your internet connection and try again."
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
