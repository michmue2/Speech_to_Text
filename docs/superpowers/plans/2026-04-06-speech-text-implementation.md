# SpeechText Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a menu-bar macOS app that records audio while the user holds the `fn` key, transcribes it locally with WhisperKit, and pastes the result into the active text field.

**Architecture:** SwiftUI `@main` app (LSUIElement, no dock icon) with four independent services: CGEventTap key listener, AVAudioEngine recorder, WhisperKit transcriber, and pasteboard-based text injector. All processing is local on Apple Silicon.

**Tech Stack:** Swift, SwiftUI, AppKit, WhisperKit (SPM), AVAudioEngine, CGEvent/CGEventTap

---

## File Structure

This creates an SPM project that produces an executable. The user will open the directory in Xcode to generate the `.xcodeproj`, set the deployment target to macOS 14, and configure LSUIElement.

| File | Purpose |
|---|---|
| `Package.swift` | SPM manifest with WhisperKit dependency |
| `speechTextApp.swift` | `@main` SwiftUI entry point, bootstrap, menu bar |
| `Models/AppState.swift` | Observable state machine (idle/recording/processing) |
| `Services/GlobalKeyListenerService.swift` | CGEventTap for fn key press/release |
| `Services/AudioRecorderService.swift` | AVAudioEngine recording to PCM buffer |
| `Services/TranscriberService.swift` | WhisperKit wrapper for audio → text |
| `Services/TextInjectorService.swift` | Pasteboard + CGEvent Cmd+V injection |

All service files are created in parallel since they have clear interfaces defined by the spec.

---

### Task 1: Initialize Swift Package

**Files:**
- Create: `/Users/michael/Desktop/speech_text/Package.swift`
- Create: `/Users/michael/Desktop/speech_text/Sources/speechTextApp/main.swift`
- Create: `/Users/michael/Desktop/speech_text/Sources/speechTextApp/Models/AppState.swift`
- Create: `/Users/michael/Desktop/speech_text/Sources/speechTextApp/Services/AudioRecorderService.swift`
- Create: `/Users/michael/Desktop/speech_text/Sources/speechTextApp/Services/GlobalKeyListenerService.swift`
- Create: `/Users/michael/Desktop/speech_text/Sources/speechTextApp/Services/TextInjectorService.swift`
- Create: `/Users/michael/Desktop/speech_text/Sources/speechTextApp/Services/TranscriberService.swift`

- [ ] Create `Package.swift`

```swift
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "speechText",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpeechText", targets: ["SpeechTextApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/whisperkit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "SpeechTextApp",
            dependencies: [
                .product(name: "WhisperKit", package: "whisperkit"),
            ],
            path: "Sources/speechTextApp"
        ),
    ]
)
```

- [ ] Create directory structure

```bash
mkdir -p /Users/michael/Desktop/speech_text/Sources/speechTextApp/Models
mkdir -p /Users/michael/Desktop/speech_text/Sources/speechTextApp/Services
```

- [ ] Commit

```bash
git add Package.swift
git commit -m "chore: initialize Swift package with WhisperKit dependency"
```

---

### Task 2: AppState Model

**Files:**
- Create: `Sources/speechTextApp/Models/AppState.swift`

- [ ] Write `AppState.swift`

```swift
import Foundation

enum AppRecordingState: String {
    case idle
    case recording
    case processing
}

@MainActor
class AppState: ObservableObject {
    @Published var state: AppRecordingState = .idle
}
```

- [ ] Verify build

```bash
swift build 2>&1 | tail -5
```
Expected: compiles successfully.

- [ ] Commit

```bash
git add Sources/speechTextApp/Models/AppState.swift
git commit -m "feat: add AppState observable state machine"
```

---

### Task 3: AudioRecorderService

**Files:**
- Create: `Sources/speechTextApp/Services/AudioRecorderService.swift`

- [ ] Write `AudioRecorderService.swift`

```swift
import Foundation
import AVFoundation

actor AudioRecorderService {
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: AVAudioPCMBuffer?
    private var isRecording: Bool = false
    private var maxDuration: TimeInterval = 30
    private var recordingTimer: DispatchSourceTimer?

    /// Start recording audio. Returns false if already recording.
    func start() async -> Bool {
        guard !isRecording else { return false }
        isRecording = true

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            Task { @MainActor [weak self] in
                await self?.onNewBuffer(buffer)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("[AudioRecorderService] Failed to start engine: \(error)")
            isRecording = false
            return false
        }

        audioEngine = engine
        setupAutoStopTimer()
        return true
    }

    /// Stop recording and return the accumulated buffer. Nil if not recording.
    func stop() async -> AVAudioPCMBuffer? {
        isRecording = false
        recordingTimer?.cancel()
        recordingTimer = nil
        let result = audioBuffer
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioBuffer = nil
        return result
    }

    /// Append incoming buffers for later transcription
    private func onNewBuffer(_ buffer: AVAudioPCMBuffer) {
        if let existing = audioBuffer {
            // Append new buffer to accumulated
            let newCapacity = existing.frameCapacity + buffer.frameLength
            if let combined = AVAudioPCMBuffer(pcmFormat: existing.format, frameCapacity: newCapacity) {
                _ = existing.append(buffer)
                audioBuffer = existing
            }
        } else {
            // First buffer — clone it
            audioBuffer = buffer.copy() as? AVAudioPCMBuffer
            audioBuffer?.frameLength = buffer.frameLength
        }
    }

    /// Auto-stop after maxDuration seconds
    private func setupAutoStopTimer() {
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        source.schedule(deadline: .now() + maxDuration)
        source.setEventHandler { [weak self] in
            Task { await self?.stop() }
        }
        source.resume()
        recordingTimer = source
    }
}
```

  Note: The `AVAudioPCMBuffer.append` method is available in AVFoundation. If it's not available, we'll manually copy the sample data. Let me adjust the buffer accumulation approach to be safer:

```swift
import Foundation
import AVFoundation

actor AudioRecorderService {
    private var audioEngine: AVAudioEngine?
    private var collectedBuffers: [AVAudioPCMBuffer] = []
    private var isRecording: Bool = false
    private var maxDuration: TimeInterval = 30
    private var recordingTimer: DispatchSourceTimer?

    /// Start recording audio. Returns false if already recording.
    func start() async -> Bool {
        guard !isRecording else { return false }
        isRecording = true
        collectedBuffers.removeAll()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            Task { await self?.collectedBuffers.append(buffer) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("[AudioRecorderService] Failed to start engine: \(error)")
            isRecording = false
            return false
        }

        audioEngine = engine
        setupAutoStopTimer()
        return true
    }

    /// Stop recording and return the accumulated buffer. Nil if not recording.
    func stop() async -> AVAudioPCMBuffer? {
        isRecording = false
        recordingTimer?.cancel()
        recordingTimer = nil
        let result = combineBuffers(collectedBuffers)
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        collectedBuffers.removeAll()
        return result
    }

    /// Combine multiple PCM buffers into a single buffer
    private func combineBuffers(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard !buffers.isEmpty else { return nil }
        guard let format = buffers.first?.format else { return nil }

        let totalFrames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard totalFrames > 0 else { return nil }

        let combined = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames))!
        for buffer in buffers {
            combined.append(buffer)
        }
        return combined
    }

    /// Auto-stop after maxDuration seconds
    private func setupAutoStopTimer() {
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        source.schedule(deadline: .now() + maxDuration)
        source.setEventHandler { [weak self] in
            Task { [weak self] in
                if let self = self {
                    await self.stop()
                }
            }
        }
        source.resume()
        recordingTimer = source
    }
}
```

- [ ] Commit

```bash
git add Sources/speechTextApp/Services/AudioRecorderService.swift
git commit -m "feat: add AudioRecorderService with AVAudioEngine recording"
```

---

### Task 4: TranscriberService

**Files:**
- Create: `Sources/speechTextApp/Services/TranscriberService.swift`

- [ ] Write `TranscriberService.swift`

```swift
import Foundation
import WhisperKit
import AVFoundation

actor TranscriberService {
    private var whisperKit: WhisperKit?
    private var isModelLoaded: Bool = false

    /// Initialize WhisperKit, downloading the model if needed
    func initialize() async throws {
        guard !isModelLoaded else { return }
        whisperKit = try await WhisperKit()
        isModelLoaded = true
    }

    /// Transcribe audio buffer to text. Returns nil if model not loaded.
    func transcribe(_ buffer: AVAudioPCMBuffer) async -> String? {
        guard let whisperKit = whisperKit else { return nil }

        // WhisperKit can transcribe from a file path or audio buffer
        // We'll write the buffer to a temporary file for WhisperKit
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recording_\(UUID().uuid6).wav6")
        do {
            try writeBufferToWAV(buffer, to: tempURL)
            let result = try await whisperKit.transcribe(audioPath: tempURL.path)
            try? FileManager.default.removeItem(at: tempURL)
            return result?.text.isEmpty == false ? result?.text : nil
        } catch {
            print("[TranscriberService] Transcription failed: \(error)")
            return nil
        }
    }

    /// Write PCM buffer to WAV file for WhisperKit
    private func writeBufferToWAV(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        var format = AudioStreamBasicDescription(
            mSampleRate: buffer.format.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        guard let audioFile = try? AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128000,
            AVLinearPCMBitDepthKey: 16,
        ]) else {
            fatalError("Failed to create WAV file")
        }

        try audioFile.write(from: buffer)
    }
}
```

- [ ] Commit

```bash
git add Sources/speechTextApp/Services/TranscriberService.swift
git commit -m "feat: add TranscriberService with WhisperKit integration"
```

---

### Task 5: TextInjectorService

**Files:**
- Create: `Sources/speechTextApp/Services/TextInjectorService.swift`

- [ ] Write `TextInjectorService.swift`

```swift
import Foundation
import AppKit

struct TextInjectorService {
    /// Inject text into the active text field by pasting via CGEvent
    func inject(_ text: String) {
        // Write to pasteboard
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)

        // Small delay to ensure pasteboard is updated
        Thread.sleep(forTimeInterval: 0.1)

        // Simulate Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)

        // Cmd down
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(55), keyDown: true)
        cmdDown?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)

        // V down + up
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(9), keyDown: true)
        vDown?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)

        let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(9), keyDown: false)
        vUp?.flags = .maskCommand
        vUp?.post(tap: .cghidEventTap)

        // Cmd up
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(55), keyDown: false)
        cmdUp?.post(tap: .cghidEventTap)
    }
}
```

- [ ] Commit

```bash
git add Sources/speechTextApp/Services/TextInjectorService.swift
git commit -m "feat: add TextInjectorService with pasteboard + CGEvent injection"
```

---

### Task 6: GlobalKeyListenerService

**Files:**
- Create: `Sources/speechTextApp/Services/GlobalKeyListenerService.swift`

- [ ] Write `GlobalKeyListenerService.swift`

```swift
import Foundation
import AppKit

@MainActor
class GlobalKeyListenerService: ObservableObject {
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?

    /// The fn key code on macOS keyboards
    private let fnKeyCode: CGKeyCode = 69

    /// Callbacks set by the app
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var isFnPressed = false

    func start() {
        let eventMask = (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let listener = Unmanaged<GlobalKeyListenerService>.fromOpaque(refcon).takeUnretainedValue()

            if type == .flagsChanged {
                let keyCode = CGEventSourceGetSourceFlags(event.flags)
                print("[KeyListener] flagsChanged: event=\(event), keyCode=\(keyCode)")
                listener.handle(event)
            }

            return Unmanaged.passRetained(event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: Unmanaged.passRetained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            print("[KeyListener] Failed to create event tap. Please grant accessibility permissions.")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    }

    private func handle(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKey)
        let key = CGKeyCode(keyCode)

        if key == fnKeyCode {
            // Check if this is a press or release
            let flags = event.flags
            if !isFnPressed && flags.contains(.maskSecondaryFn) {
                isFnPressed = true
                onKeyDown?()
            } else if isFnPressed && !flags.contains(.maskSecondaryFn) {
                isFnPressed = false
                onKeyUp?()
            }
        }
    }
}
```

- [ ] Commit

```bash
git add Sources/speechTextApp/Services/GlobalKeyListenerService.swift
git commit -m "feat: add GlobalKeyListenerService with CGEventTap"
```

---

### Task 7: Main App & Menu Bar Entry Point

**Files:**
- Create: `Sources/speechTextApp/main.swift` (replaces the stub)

- [ ] Write `main.swift`

```swift
import SwiftUI
import AppKit

@main
struct SpeechTextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            EmptyView()
        }
        .windowStyle(HiddenTitleBarWindowStyle())
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var appState: AppState!
    var appStateViewModel: AppViewModel!
    var keyListener: GlobalKeyListenerService!
    var audioRecorder = AudioRecorderService()
    var transcriber = TranscriberService()
    let textInjector = TextInjectorService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up app state
        appState = AppState()
        appStateViewModel = AppViewModel(appState: appState)

        // Hide dock
        NSApp.setActivationPolicy(.accessory)

        // Set up menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙"
        statusItem.menu = buildMenu()

        // Initialize WhisperKit in background
        Task.detached {
            do {
                try await self.transcriber.initialize()
            } catch {
                print("[App] Failed to initialize WhisperKit: \(error)")
            }
        }

        // Set up key listener
        keyListener = GlobalKeyListenerService()
        keyListener.onKeyDown = { [weak self] in
            Task { await self?.handleKeyDown() }
        }
        keyListener.onKeyUp = { [weak self] in
            Task { await self?.handleKeyUp() }
        }
        keyListener.start()
    }

    @MainActor
    private func handleKeyDown() async {
        guard appState.state == .idle else { return }
        appState.state = .recording
        statusItem.button?.title = "🎙"
        statusItem.button?.appearsDisabled = false
        let started = await audioRecorder.start()
        if !started {
            appState.state = .idle
        }
    }

    @MainActor
    private func handleKeyUp() async {
        guard appState.state == .recording else { return }
        appState.state = .processing
        statusItem.button?.title = "⏳"

        let buffer = await audioRecorder.stop()
        guard let buffer = buffer else {
            appState.state = .idle
            statusItem.button?.title = "🎙"
            return
        }

        // Transcribe
        let transcript = await transcriber.transcribe(buffer)
        guard let transcript = transcript, !transcript.isEmpty else {
            appState.state = .idle
            statusItem.button?.title = "🎙"
            return
        }

        // Inject text
        textInjector.inject(transcript)

        // Reset state
        appState.state = .idle
        statusItem.button?.title = "🎙"
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "SpeechText Active", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "About SpeechText", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "SpeechText"
        alert.informativeText = "Dictate with the fn key. Runs locally with WhisperKit."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
class AppViewModel: ObservableObject {
    @Published var state: String = "idle"
    private var appState: AppState
    private var cancellables: Set<any AnyCancellable> = []

    init(appState: AppState) {
        self.appState = appState
        // Bind state changes
        appState.statePublisher.sink { [weak self] newState in
            self?.state = newState.stringValue
        }.store(in: &cancellables)
    }
}
```

- [ ] Verify build

```bash
swift build 2>&1 | tail -20
```

Expected: compiles successfully.

- [ ] Commit

```bash
git add Sources/speechTextApp/main.swift
git commit -m "feat: add menu bar app with full dictation pipeline"
```

---

## Post-Setup: Xcode Configuration

After implementation, the user should:

1. Open `/Users/michael/Desktop/speech_text` in Xcode — it will auto-generate the `.xcodeproj`
2. Set deployment target to macOS 14
3. Add `NSMicrophoneUsageDescription` to Info.plist (required for audio recording)
4. Optionally enable Accessibility API for text injection (though CGEvent paste simulation works without it)
5. Build and Run (⌘R)

## Testing

Since this is a deeply system-integrated app (global key events, microphone, pasteboard injection), automated unit tests are impractical. Manual testing checklist:

1. Launch app → dock icon hidden, menu bar icon visible
2. Press and hold `fn` key → menu bar icon changes to recording state
3. Speak for 2-3 seconds
4. Release `fn` key → icon shows processing, then text is pasted into active field
5. Hold `fn` for >30 seconds → recording auto-stops
6. Press `fn` with no text field focused → notification shown
7. First launch → WhisperKit model downloads transparently
