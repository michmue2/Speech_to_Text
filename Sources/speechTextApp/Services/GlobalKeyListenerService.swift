import AppKit
import Carbon.HIToolbox

class GlobalKeyListenerService: ObservableObject {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?

    /// Right option key code (kVK_RightOption = 0x3D)
    private static let rightOptionKeyCode: UInt16 = 0x3D

    private var isPressed = false
    private var monitors: [Any] = []

    func start() {
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        // Also monitor flagsChanged for modifier key state
        NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        print("[KeyListener] Global monitors active, watching right option key")
    }

    private func handleKeyEvent(_ event: NSEvent) {
        if event.keyCode == Self.rightOptionKeyCode {
            if event.type == .keyDown && !isPressed {
                isPressed = true
                onDown?()
            } else if event.type == .keyUp && isPressed {
                isPressed = false
                onUp?()
            }
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags
        let hasOption = flags.contains(.option)

        if hasOption && !isPressed {
            isPressed = true
            onDown?()
        } else if !hasOption && isPressed {
            isPressed = false
            onUp?()
        }
    }
}
