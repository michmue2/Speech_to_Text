import ApplicationServices

@MainActor
class GlobalKeyListenerService: ObservableObject {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// The fn key code on macOS (63 = 0x3F)
    private let fnKeyCode: CGKeyCode = 63

    /// Callbacks set by the app
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var isFnPressed = false

    func start() {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let listener = Unmanaged<GlobalKeyListenerService>.fromOpaque(refcon).takeUnretainedValue()

                if type == .flagsChanged {
                    listener.handleFlagsChanged(event)
                }

                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            print("[KeyListener] Failed to create event tap. Check accessibility permissions.")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        print("[KeyListener] Event tap created, listening for fn key")
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        // Get the key code from the event
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let eventFlags = event.flags.rawValue

        if keyCode == fnKeyCode {
            let secondaryFn = (eventFlags & 0x00800000) != 0

            if secondaryFn && !isFnPressed {
                isFnPressed = true
                onKeyDown?()
            } else if !secondaryFn && isFnPressed {
                isFnPressed = false
                onKeyUp?()
            }
        }
    }

    func stop() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }
}
