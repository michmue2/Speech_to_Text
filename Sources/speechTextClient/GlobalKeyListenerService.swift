import AppKit
import Combine
import Carbon.HIToolbox

class GlobalKeyListenerService: ObservableObject {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?

    private var isPressed = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { [weak self] (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return nil }
                let listener = Unmanaged<GlobalKeyListenerService>.fromOpaque(refcon).takeUnretainedValue()
                listener.onFlagsChanged(event)
                return nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = eventTap else {
            print("[KeyListener] Failed to create event tap")
            return
        }

        CGEvent.tapEnable(tap: tap, enable: true)
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        print("[KeyListener] Event tap active")
    }

    private func onFlagsChanged(_ event: CGEvent) {
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
