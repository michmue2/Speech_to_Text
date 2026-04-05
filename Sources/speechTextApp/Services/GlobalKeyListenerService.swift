import AppKit
import Carbon.HIToolbox

class GlobalKeyListenerService: ObservableObject {
    /// Right option key: KeyCode 0x3D (61), Carbon equivalent kVK_RightOption
    private static let rightOptionKeyCode: UInt32 = 61  // 0x3D

    var onDown: (() -> Void)?
    var onUp: (() -> Void)?

    private var downHotKey: EventHotKeyRef?
    private var upHotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var eventRef: Unmanaged<EventRecord>?
    private var isPressed = false

    func start() {
        // Register two Carbon hotkeys: one for key down, one for key up
        // macOS doesn't generate hotkey events for modifier-only keys
        // So we use an event tap at the session level for flagsChanged,
        // but without blocking - we use .listenOnly mode

        // CGEventTap with .listenOnly (passive) - doesn't intercept events, just observes
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,  // Passive - doesn't block or modify events
            eventsOfInterest: CGEventMask(eventMask),
            callback: { [weak self] (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return nil }
                let listener = Unmanaged<GlobalKeyListenerService>.fromOpaque(refcon).takeUnretainedValue()
                listener.onFlagsChanged(event)
                return nil  // .listenOnly doesn't return events
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = eventTap else {
            print("[KeyListener] Failed to create event tap")
            return
        }

        // Enable the tap (may need accessibility permissions)
        CGEvent.tapEnable(tap: tap, enable: true)

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        print("[KeyListener] Event tap active (listen-only)")
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private func onFlagsChanged(_ event: CGEvent) {
        // Only look at events without command/shift/control/option modifiers
        let flags = event.flags
        let hasOption = flags.contains(.maskAlternate)
        let hasOther = flags.contains(.maskCommand) || flags.contains(.maskShift) || flags.contains(.maskControl)

        if hasOption && !hasOther && !isPressed {
            isPressed = true
            DispatchQueue.main.async { [weak self] in self?.onDown?() }
        } else if !hasOption && isPressed {
            isPressed = false
            DispatchQueue.main.async { [weak self] in self?.onUp?() }
        }
    }
}
