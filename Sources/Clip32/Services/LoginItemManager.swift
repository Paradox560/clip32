import AppKit
import ServiceManagement

@MainActor
final class LoginItemManager {
    private let defaults: UserDefaults
    private let attemptedKey = "Clip32.loginItemRegistrationAttempted"
    private let service = SMAppService.mainApp

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool { service.status == .enabled }
    var requiresApproval: Bool { service.status == .requiresApproval }

    var statusDescription: String {
        switch service.status {
        case .enabled: return "Clip32 opens automatically when you log in."
        case .notRegistered: return "Launch at login is off."
        case .requiresApproval: return "Allow Clip32 in System Settings → General → Login Items."
        case .notFound: return "Open the installed Clip32.app to enable launch at login."
        @unknown default: return "Check Clip32 in System Settings → General → Login Items."
        }
    }

    enum LoginError: LocalizedError {
        case applicationBundleRequired

        var errorDescription: String? {
            "Launch at login requires the installed Clip32.app. Open it from Applications, then enable Launch at login in Settings."
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else {
            throw LoginError.applicationBundleRequired
        }
        defaults.set(true, forKey: attemptedKey)
        if enabled {
            if service.status != .enabled && service.status != .requiresApproval {
                try service.register()
            }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    }

    /// The requested default is on. Attempt once; never override a later choice
    /// made by the user in Clip32 or in System Settings.
    func enableOnFirstLaunch() throws {
        guard !defaults.bool(forKey: attemptedKey) else { return }
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else {
            throw LoginError.applicationBundleRequired
        }
        defaults.set(true, forKey: attemptedKey)
        try setEnabled(true)
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
