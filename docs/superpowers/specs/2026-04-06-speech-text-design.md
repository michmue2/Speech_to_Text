# SpeechText - Design Document

## Overview

A menu-bar-only macOS application that lets users dictate text anywhere on their system by holding the `fn` key. Audio is recorded locally while the key is held, transcribed on release using WhisperKit (tiny model), and injected into the active text field via pasteboard.

## Architecture

```
[fn key down] → Global Key Listener → [start recording]
                                     ↓
                              AVAudioEngine (mono, 16kHz)
                                     ↓
[fn key up]  → [stop recording] → AudioPCMBuffer
                                     ↓
                              WhisperKit (off main thread)
                                     ↓
                              Transcript string
                                     ↓
                              NSPasteboard.general.setString()
                                     ↓
                              CGEvent Cmd+V → active app text field
```

## Components

### App Entry Point
- SwiftUI `@main` app with `LSUIElement: true` (no dock icon, no main window)
- No application window — purely menu-bar resident
- Instantiates all services on launch

### AppState
- Single `ObservableObject` tracking three states:
  - `idle` — default, default menu bar icon
  - `recording` — audio captured, pulsing indicator
  - `processing` — running WhisperKit, spinning indicator
- Exposed via `NSStatusItem` icon

### GlobalKeyListenerService
- `CGEventTap` at `kCGSessionEventTap` level monitoring `flagsChanged` events
- Detects `fn` key press (kCGKeyCodeFN / kCGEventFlagMaskAuxilliary)
- Runs on dedicated dispatch queue, not main thread
- On key-down: signals `AudioRecorderService.start()`
- On key-up: signals `AudioRecorderService.stop()` then triggers transcription

### AudioRecorderService
- `AVAudioEngine` configured for mono, 16kHz, 16-bit PCM
- Records to in-memory `AVAudioPCMBuffer` (no file I/O)
- Maximum duration: ~30 seconds (configurable), then auto-stop
- On stop, passes buffer to `TranscriberService`

### TranscriberService
- WhisperKit Swift Package with `tiny` model
- First launch: downloads model (~40MB) to `~/Library/Application Support/`
- Subsequent launches: loads from disk
- Runs off main thread on a `Task.detached`
- Returns transcript string
- Language: English only
  - Handles cases where WhisperKit fails to load or returns empty
  - Shows menu bar notification for model load failures

### TextInjectorService
- Writes transcript string to `NSPasteboard.general`
- Simulates Cmd+V via `CGEvent.keyboard()`
- Checks frontmost app accepts text input before injecting
- Shows macOS notification if no text field is focused

### Menu Bar UI
- `NSStatusItem` with variable title/icon
- Three visual states:
  - Idle: microphone icon
  - Recording: icon with pulsing red dot
  - Processing: icon with spinner animation
- Menu items: About, Settings, Quit
- Settings (future): configurable hotkey, language, max duration

## Error Handling

| Scenario | Behavior |
|---|---|
| WhisperKit model not loaded | Show menu bar alert, don't inject |
| Empty transcript (no speech) | No action, no paste |
| Can't inject (no focused text field) | Brief macOS notification |
| Key held >30 seconds | Auto-stop recording, subtle warning |
| WhisperKit fails | Show toast notification, don't inject |
| First launch | Transparent model download, show progress in menu bar |

## File Structure

```
SpeechText/
├── SpeechTextApp.swift              # @main, bootstraps everything
├── Models/
│   └── AppState.swift              # Observable state machine
├── Services/
│   ├── GlobalKeyListenerService.swift # CGEventTap for fn key
│   ├── AudioRecorderService.swift   # AVAudioEngine recording
│   ├── TranscriberService.swift     # WhisperKit wrapper
│   └── TextInjectorService.swift    # Pasteboard + CGEvent
└── Resources/
    ├── Icons/                       # Menu bar icons (3 states)
    │   ├── idle-icon.png
    │   ├── recording-icon.png
    │   └── processing-icon.png
    └── Info.plist                   # LSUIElement: true
```

## Dependencies

- **WhisperKit** — local Apple Silicon speech-to-text model (Swift Package)
- **KeyboardShortcuts** (Sindresorhus) — optional, for future hotkey customization
- **SwiftUI / AppKit** — native macOS stack
- No network APIs — all processing runs locally

## Platform Requirements

- macOS 14+ (Sonoma or later) — required for WhisperKit
- Apple Silicon (M1/M2/M3/M4) — WhisperKit only runs on Apple Silicon
- Accessibility permission — required for text injection
