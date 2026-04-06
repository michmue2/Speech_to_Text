import AppKit
import Foundation

/// SpeechTextClient — menu bar dictation app that sends audio to a remote server
/// Configuration via environment variables or ~/.speechtext-client.config

struct ClientConfig {
    let serverURL: URL
    let authToken: String
    let hotkeyKeyCode: CGKeyCode

    static func load() -> ClientConfig {
        // Try env vars first, then config file, then defaults
        let envURL = ProcessInfo.processInfo.environment["SPEECHTEXT_SERVER"]
        let envToken = ProcessInfo.processInfo.environment["SPEECHTEXT_TOKEN"]

        return ClientConfig(
            serverURL: URL(string: envURL ?? "http://localhost:8080/transcribe")!,
            authToken: envToken ?? "speechtext-secret",
            hotkeyKeyCode: 61  // Right Option
        )
    }
}

class ClientAppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var keyListener: GlobalKeyListenerService!
    var audioRecorder: AudioRecorderService!
    let transcriber: RemoteTranscriberService!
    let textInjector = TextInjectorService()
    let config: ClientConfig

    override init() {
        config = ClientConfig.load()
        transcriber = RemoteTranscriberService(serverURL: config.serverURL, authToken: config.authToken)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        audioRecorder = AudioRecorderService()
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙"
        statusItem.menu = buildMenu()

        keyListener = GlobalKeyListenerService()
        keyListener.onDown = { [weak self] in
            Task { await self?.handleKeyDown() }
        }
        keyListener.onUp = { [weak self] in
            Task { await self?.handleKeyUp() }
        }
        keyListener.start()

        print("[Client] Configured to connect to \(config.serverURL)")
    }

    @MainActor func handleKeyDown() async {
        guard statusItem.button?.title == "🎙" else { return }
        statusItem.button?.title = "●"
        let started = await audioRecorder.start()
        if !started {
            statusItem.button?.title = "🎙"
        }
    }

    @MainActor func handleKeyUp() async {
        guard statusItem.button?.title == "●" else { return }
        statusItem.button?.title = "⏳"

        let buffer = await audioRecorder.stop()
        guard let buffer = buffer else {
            statusItem.button?.title = "🎙"
            return
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("speechtext_client.wav")
        do {
            try AudioRecorderService.writeBufferToWAV(buffer, to: tempURL)
            let transcript = await transcriber.transcribeFile(path: tempURL.path)
            try? FileManager.default.removeItem(at: tempURL)

            guard let transcript = transcript else {
                statusItem.button?.title = "🎙"
                return
            }

            textInjector.inject(transcript)
            statusItem.button?.title = "🎙"
        } catch {
            NSLog("[Client] Failed: \(error)")
            statusItem.button?.title = "🎙"
        }
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Connected to \(config.serverURL.host ?? "server")", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}

let delegate = ClientAppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
