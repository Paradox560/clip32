import AppKit
import ApplicationServices
import Carbon

@MainActor
final class PasteService {
    private var activeRequest: UUID?

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Call only in response to the user's direct-paste or Enable action.
    @discardableResult
    func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The caller restores the clipboard and dismisses its panel before calling.
    /// Success means a paste command was delivered, not that the destination
    /// field accepted it (apps do not report that back to a clipboard manager).
    func paste(into app: NSRunningApplication, completion: @escaping (Bool) -> Void) {
        guard accessibilityGranted, !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            completion(false)
            return
        }

        let request = UUID()
        activeRequest = request
        let initiatingPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard app.activate(options: [.activateIgnoringOtherApps]) else {
            activeRequest = nil
            completion(false)
            return
        }
        awaitFocus(app, request: request, initiatingPID: initiatingPID, attempts: 16, completion: completion)
    }

    func cancelPendingPaste() {
        activeRequest = nil
    }

    private func awaitFocus(_ app: NSRunningApplication, request: UUID, initiatingPID: pid_t?,
                            attempts: Int, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { completion(false); return }
            guard self.activeRequest == request, self.accessibilityGranted,
                  !app.isTerminated else { completion(false); return }

            let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if foregroundPID == app.processIdentifier {
                self.activeRequest = nil
                self.sendPaste(to: app, completion: completion)
                return
            }

            // If the user has moved to another app, abandon this paste rather
            // than stealing focus back or typing into that unrelated app.
            let ownPID = ProcessInfo.processInfo.processIdentifier
            guard attempts > 0,
                  foregroundPID == initiatingPID || foregroundPID == ownPID || foregroundPID == nil else {
                self.activeRequest = nil
                completion(false)
                return
            }
            self.awaitFocus(app, request: request, initiatingPID: initiatingPID,
                            attempts: attempts - 1, completion: completion)
        }
    }

    private func sendPaste(to app: NSRunningApplication, completion: @escaping (Bool) -> Void) {
        guard accessibilityGranted, !app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            completion(false)
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        // Target the captured process so a last-moment focus switch cannot send
        // the clipboard to an unrelated app between this check and dispatch.
        keyDown.postToPid(app.processIdentifier)
        keyUp.postToPid(app.processIdentifier)
        completion(true)
    }
}
