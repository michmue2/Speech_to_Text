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
        usleep(100_000) // 100ms

        // Simulate Cmd+V via CGEvent
        let source = CGEventSource(stateID: .hidSystemState)

        // Cmd down
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x37), keyDown: true)
        cmdDown?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)

        // V down
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x09), keyDown: true)
        vDown?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)

        // V up
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x09), keyDown: false)
        vUp?.flags = .maskCommand
        vUp?.post(tap: .cghidEventTap)

        // Cmd up
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x37), keyDown: false)
        cmdUp?.post(tap: .cghidEventTap)
    }
}
