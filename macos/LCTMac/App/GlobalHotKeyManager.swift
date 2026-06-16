import AppKit
import Carbon.HIToolbox

/// Registers system-wide hotkeys via Carbon's RegisterEventHotKey.
///
/// Unlike NSEvent global monitors, this needs no Accessibility/Input-Monitoring
/// permission — the OS notifies us only when our specific chord fires, rather
/// than us observing every keystroke. Hotkey presses post the same
/// Notifications the in-app menu/commands already use, so there's no coupling
/// to the view model.
///
/// Default chords (control-option-command + key, chosen to avoid clashing with
/// system shortcuts like ⌘Space Spotlight):
///   ⌃⌥⌘ S — start/stop capture
///   ⌃⌥⌘ P — pause/resume
///   ⌃⌥⌘ O — toggle overlay
@MainActor
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private var installed = false

    private init() {}

    /// Carbon hotkey identifiers; the C handler maps these to Notifications.
    private enum Action: UInt32 {
        case toggleCapture = 1
        case togglePause = 2
        case toggleOverlay = 3
    }

    func registerDefaults() {
        guard !installed else { return }
        installed = true

        installHandler()
        register(.toggleCapture, keyCode: UInt32(kVK_ANSI_S))
        register(.togglePause, keyCode: UInt32(kVK_ANSI_P))
        register(.toggleOverlay, keyCode: UInt32(kVK_ANSI_O))
    }

    func unregister() {
        for ref in hotKeyRefs where ref != nil {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        eventHandler = nil
        installed = false
    }

    // MARK: - Carbon plumbing

    private func installHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // The handler is a C function pointer: it captures nothing and only
        // touches thread-safe APIs (GetEventParameter, NotificationCenter.post),
        // so it is safe to invoke from Carbon's nonisolated callback context.
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    UInt32(kEventParamDirectObject),
                    UInt32(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }

                let name: Notification.Name?
                switch hotKeyID.id {
                case Action.toggleCapture.rawValue: name = .toggleCapture
                case Action.togglePause.rawValue: name = .togglePause
                case Action.toggleOverlay.rawValue: name = .toggleOverlay
                default: name = nil
                }

                if let name {
                    // object: nil → the .toggleCapture observer treats this as a
                    // toggle (start if stopped, stop if running).
                    NotificationCenter.default.post(name: name, object: nil)
                }
                return noErr
            },
            1,
            &spec,
            nil,
            &eventHandler
        )
    }

    private func register(_ action: Action, keyCode: UInt32) {
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        // Signature 'LCT!' scopes our hotkey ids.
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C43_5421), id: action.rawValue)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr {
            hotKeyRefs.append(ref)
        } else {
            appLog("[GlobalHotKey] Failed to register \(action) (status \(status)) — chord may be taken")
        }
    }
}
