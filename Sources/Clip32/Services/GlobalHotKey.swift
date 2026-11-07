import AppKit
import Carbon

enum HotKeyChoice: String, CaseIterable, Identifiable {
    case commandShiftC
    case controlOptionC
    case commandOptionC

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .commandShiftC: return "⌘⇧C"
        case .controlOptionC: return "⌃⌥C"
        case .commandOptionC: return "⌘⌥C"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .commandShiftC: return "Command Shift C"
        case .controlOptionC: return "Control Option C"
        case .commandOptionC: return "Command Option C"
        }
    }

    fileprivate var carbonModifiers: UInt32 {
        switch self {
        case .commandShiftC: return UInt32(cmdKey | shiftKey)
        case .controlOptionC: return UInt32(controlKey | optionKey)
        case .commandOptionC: return UInt32(cmdKey | optionKey)
        }
    }
}

/// Carbon's hot-key API reserves only this shortcut. It does not observe typing
/// and does not require Input Monitoring or Accessibility permission.
final class GlobalHotKey {
    static let choices = HotKeyChoice.allCases
    private static let signature: OSType = 0x43333248 // C32H

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (() -> Void)?
    private var registeredChoice: HotKeyChoice?
    private var identifier: UInt32 = 0

    enum RegistrationError: LocalizedError {
        case handler(OSStatus)
        case shortcut(HotKeyChoice, OSStatus)

        var errorDescription: String? {
            switch self {
            case .handler(let status):
                return "Clip32 could not listen for its shortcut (error \(status)). You can still open history from the menu bar."
            case .shortcut(let choice, let status):
                return "\(choice.displayName) could not be registered (error \(status)). It may be used by another app. Choose a different shortcut in Settings."
            }
        }
    }

    func register(choice: HotKeyChoice = .commandShiftC, action: @escaping () -> Void) throws {
        if hotKey != nil, registeredChoice == choice {
            self.action = action
            return
        }

        if eventHandler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                              EventParamType(typeEventHotKeyID), nil,
                                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard status == noErr else { return status }
                let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                guard hotKeyID.signature == GlobalHotKey.signature,
                      hotKeyID.id == owner.identifier else { return OSStatus(eventNotHandledErr) }
                // Carbon dispatches through the main event loop. Queue the UI
                // work so opening a panel does not reenter the event handler.
                DispatchQueue.main.async { [weak owner] in owner?.action?() }
                return noErr
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
            guard result == noErr else { throw RegistrationError.handler(result) }
        }

        let nextIdentifier = identifier &+ 1
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: nextIdentifier)
        var candidate: EventHotKeyRef?
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_C), choice.carbonModifiers,
                                         hotKeyID, GetApplicationEventTarget(), 0, &candidate)
        guard result == noErr, let candidate else {
            throw RegistrationError.shortcut(choice, result)
        }

        // Keep the existing shortcut working when a replacement is unavailable.
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = candidate
        identifier = nextIdentifier
        registeredChoice = choice
        self.action = action
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registeredChoice = nil
        action = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    deinit { unregister() }
}
