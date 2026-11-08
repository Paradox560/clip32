import AppKit
import ServiceManagement

@MainActor
protocol LoginItemServicing {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemServicing {}

@MainActor
final class LoginItemManager {
    private let defaults: UserDefaults
    private let attemptedKey = "Clip32.loginItemRegistrationAttempted"
    private let desiredKey = "Clip32.launchAtLoginDesired"
    private let service: any LoginItemServicing
    private let isAppBundle: Bool

    init(defaults: UserDefaults = .standard, service: (any LoginItemServicing)? = nil, isAppBundle: Bool? = nil) {
        self.defaults = defaults
        self.service = service ?? SMAppService.mainApp
        self.isAppBundle = isAppBundle ?? (Bundle.main.bundleURL.pathExtension.lowercased() == "app")
    }

    var isEnabled: Bool { service.status == .enabled }
    var requiresApproval: Bool { service.status == .requiresApproval }

    var statusDescription: String {
        switch service.status {
        case .enabled: return "Clip32 opens automatically when you log in."
        case .notRegistered: return "Launch at login is off."
        case .requiresApproval: return "Allow Clip32 in System Settings → General → Login Items."
        case .notFound: return isAppBundle ? "Enable launch at login again for this copy of Clip32." : "Open the installed Clip32.app to enable launch at login."
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
        guard isAppBundle else {
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
        // Save a preference only after the requested change succeeds. In particular,
        // an explicit off choice must survive an app replacement that reports notFound.
        defaults.set(enabled, forKey: desiredKey)
    }

    /// Default to on for a new installation. Replacing an ad-hoc signed bundle can
    /// leave an attempted registration at notFound; repair that stale registration
    /// without overriding an explicit off choice or an external notRegistered state.
    func enableOnFirstLaunch() throws {
        if defaults.object(forKey: desiredKey) as? Bool == false { return }
        if defaults.bool(forKey: attemptedKey) {
            guard service.status == .notFound else { return }
        }
        try setEnabled(true)
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
