# SpeechText

A menu-bar macOS app that lets you dictate text anywhere by holding the **fn** key. Runs entirely locally using [WhisperKit](https://github.com/argmaxinc/whisperkit) — no cloud APIs.

## Requirements

- macOS 14+ (Sonoma)
- Apple Silicon (M1/M2/M3/M4)

## Setup

1. Open the project folder in **Xcode 16+**:
   ```
   open /Users/michael/Desktop/speech_text -a Xcode.app
   ```

2. Xcode will auto-generate the project from `Package.swift`.

3. In the project settings, go to **Signing & Capabilities** and ensure your team is set.

4. Xcode should auto-generate an `Info.plist` from the Swift manifest. Add the following:
   - **Application is agent (UIElement)** = `YES` (makes it menu-bar only, no dock icon)
   - **Privacy - Microphone Usage Description** = "SpeechText needs microphone access to record your voice for transcription."

5. **Build & Run** (⌘R). The app appears in the menu bar as 🎙.

6. **Grant microphone permission** when prompted.

## Usage

- **Press and hold** the `fn` key (globe key) to start recording.
- **Speak** into your microphone.
- **Release** the key to stop recording and transcribe.
- The text is automatically pasted into the active text field.

## Architecture

- **GlobalKeyListenerService** — CGEventTap detecting fn key press/release
- **AudioRecorderService** — AVAudioEngine recording to in-memory PCM buffers
- **TranscriberService** — WhisperKit for local speech-to-text
- **TextInjectorService** — NSPasteboard + CGEvent Cmd+V for text insertion

All processing runs locally on-device. No network calls required.
