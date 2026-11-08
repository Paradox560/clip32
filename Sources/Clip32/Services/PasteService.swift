import AppKit
import ApplicationServices
import Carbon

@MainActor
final class PasteService {
    struct Target {
        let processIdentifier: pid_t
        let isTerminated: () -> Bool
        let activate: () -> Bool
    }

    /// Replaceable system boundaries let tests verify the race without posting events.
    struct Environment {
        var accessibilityGranted: () -> Bool = { AXIsProcessTrusted() }
        var pasteboardChangeCount: () -> Int = { NSPasteboard.general.changeCount }
        var foregroundPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        var ownPID: () -> pid_t = { ProcessInfo.processInfo.processIdentifier }
        var schedule: (@escaping () -> Void) -> Void = { action in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { action() }
        }
        var postPaste: (pid_t) -> Bool = { pid in
            guard let source = CGEventSource(stateID: .privateState),
                  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return false }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.postToPid(pid)
            keyUp.postToPid(pid)
            return true
        }
    }

    private var activeRequest: UUID?
    private let environment: Environment

    init(environment: Environment = Environment()) { self.environment = environment }

    var accessibilityGranted: Bool { environment.accessibilityGranted() }

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
    func paste(into app: NSRunningApplication, expectedChangeCount: Int, completion: @escaping (Bool) -> Void) {
        let target = Target(processIdentifier: app.processIdentifier,
                            isTerminated: { app.isTerminated },
                            activate: { app.activate(options: [.activateIgnoringOtherApps]) })
        paste(to: target, expectedChangeCount: expectedChangeCount, completion: completion)
    }

    func paste(to target: Target, expectedChangeCount: Int, completion: @escaping (Bool) -> Void) {
        guard accessibilityGranted, !target.isTerminated(),
              target.processIdentifier != environment.ownPID(),
              environment.pasteboardChangeCount() == expectedChangeCount else {
            completion(false)
            return
        }

        let request = UUID()
        activeRequest = request
        let initiatingPID = environment.foregroundPID()
        guard target.activate() else {
            activeRequest = nil
            completion(false)
            return
        }
        awaitFocus(target, request: request, expectedChangeCount: expectedChangeCount, initiatingPID: initiatingPID, attempts: 16, completion: completion)
    }

    func cancelPendingPaste() {
        activeRequest = nil
    }

    private func awaitFocus(_ target: Target, request: UUID, expectedChangeCount: Int, initiatingPID: pid_t?,
                            attempts: Int, completion: @escaping (Bool) -> Void) {
        environment.schedule { [weak self] in
            guard let self else { completion(false); return }
            guard self.activeRequest == request, self.accessibilityGranted,
                  !target.isTerminated(),
                  self.environment.pasteboardChangeCount() == expectedChangeCount else {
                if self.activeRequest == request { self.activeRequest = nil }
                completion(false)
                return
            }

            let foregroundPID = self.environment.foregroundPID()
            if foregroundPID == target.processIdentifier {
                self.activeRequest = nil
                self.sendPaste(to: target, expectedChangeCount: expectedChangeCount, completion: completion)
                return
            }

            // If the user has moved to another app, abandon this paste rather
            // than stealing focus back or typing into that unrelated app.
            let ownPID = self.environment.ownPID()
            guard attempts > 0,
                  foregroundPID == initiatingPID || foregroundPID == ownPID || foregroundPID == nil else {
                self.activeRequest = nil
                completion(false)
                return
            }
            self.awaitFocus(target, request: request, expectedChangeCount: expectedChangeCount, initiatingPID: initiatingPID,
                            attempts: attempts - 1, completion: completion)
        }
    }

    private func sendPaste(to target: Target, expectedChangeCount: Int, completion: @escaping (Bool) -> Void) {
        guard accessibilityGranted, !target.isTerminated(),
              environment.foregroundPID() == target.processIdentifier,
              environment.pasteboardChangeCount() == expectedChangeCount else {
            completion(false)
            return
        }
        // Target the captured process so a last-moment focus switch cannot send
        // the clipboard to an unrelated app between this check and dispatch.
        // macOS offers no atomic clipboard-and-paste transaction; the change-count
        // guard prevents a replacement during our focus wait from being pasted.
        completion(environment.postPaste(target.processIdentifier))
    }
}
