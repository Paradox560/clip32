import AppKit

@main
struct Clip32Application {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        if CommandLine.arguments.contains("--status") {
            let login = LoginItemManager()
            let report: [String: Any] = ["bundlePath": Bundle.main.bundlePath,
                "launchAtLogin": login.isEnabled, "loginRequiresApproval": login.requiresApproval,
                "loginStatus": login.statusDescription,
                "accessibilityGranted": PasteService().accessibilityGranted]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
            return
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}
