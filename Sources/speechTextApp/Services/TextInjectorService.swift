import Foundation
import AppKit

struct TextInjectorService {
    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
            let items: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.map { item in
                var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        dataByType[type] = data
                    }
                }
                return dataByType
            } ?? []

            return PasteboardSnapshot(items: items)
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()

            let pasteboardItems = items.map { dataByType in
                let item = NSPasteboardItem()
                for (type, data) in dataByType {
                    item.setData(data, forType: type)
                }
                return item
            }

            if !pasteboardItems.isEmpty {
                pasteboard.writeObjects(pasteboardItems)
            }
        }
    }

    /// Inject text into the active text field by pasting via CGEvent
    func inject(_ text: String) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        // Write to pasteboard
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        let injectedChangeCount = pasteboard.changeCount

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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let pasteboard = NSPasteboard.general
            guard
                pasteboard.changeCount == injectedChangeCount ||
                pasteboard.string(forType: .string) == text
            else {
                return
            }

            snapshot.restore(to: pasteboard)
        }
    }
}
