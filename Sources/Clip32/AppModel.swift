import AppKit
import Combine
import ClipCore

@MainActor
final class AppModel: ObservableObject {
    let store: HistoryStore
    let monitor: ClipboardMonitor
    let hotKey = GlobalHotKey()
    let login = LoginItemManager()
    let pasteService = PasteService()
    let isDemo: Bool
    @Published var shortcut: HotKeyChoice
    @Published private(set) var shortcutActive = false
    @Published var directPaste: Bool {
        didSet { if !isDemo { UserDefaults.standard.set(directPaste, forKey: "directPaste") } }
    }
    @Published var accessibilityGranted = false
    @Published var loginEnabled = false
    @Published var loginStatus = ""
    @Published var message: String?
    @Published var presentationID = UUID()
    var showHistory: (() -> Void)?
    var dismissHistory: (() -> Void)?
    var showSettings: (() -> Void)?
    var handleHistoryKey: ((NSEvent) -> Bool)?
    var previousApplication: NSRunningApplication?
    private var observers: [NSObjectProtocol] = []

    init(demo: Bool = false) {
        isDemo = demo
        shortcut = HotKeyChoice(rawValue: UserDefaults.standard.string(forKey: "shortcut") ?? "") ?? .commandShiftC
        directPaste = UserDefaults.standard.object(forKey: "directPaste") as? Bool ?? true
        if demo {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Clip32-preview-\(UUID().uuidString)")
            store = HistoryStore(directory: folder)
            monitor = ClipboardMonitor(store: store, pasteboard: NSPasteboard(name: .init("Clip32.preview.\(UUID().uuidString)")))
        } else {
            store = HistoryStore()
            monitor = ClipboardMonitor(store: store)
        }
    }

    func start() {
        refreshPermissions()
        guard !isDemo else { seedDemo(); return }
        changeShortcut(shortcut)
        monitor.start()
        do { try login.enableOnFirstLaunch() } catch { message = "Launch at login: \(error.localizedDescription)" }
        refreshPermissions()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.monitor.captureNow() }
        })
    }

    func refreshPermissions() {
        accessibilityGranted = pasteService.accessibilityGranted
        loginEnabled = login.isEnabled
        loginStatus = login.statusDescription
    }

    func changeShortcut(_ choice: HotKeyChoice) {
        do {
            try hotKey.register(choice: choice) { [weak self] in self?.showHistory?() }
            shortcutActive = true
            shortcut = choice
            UserDefaults.standard.set(choice.rawValue, forKey: "shortcut")
            message = nil
        } catch { message = "Couldn’t use \(choice.displayName). Choose another shortcut in Settings. \(error.localizedDescription)" }
    }

    func setLogin(_ enabled: Bool) {
        do { try login.setEnabled(enabled) } catch { message = "Launch at login: \(error.localizedDescription)" }
        refreshPermissions()
    }

    func enableAccessibility() {
        _ = pasteService.requestAccessibility()
        pasteService.openAccessibilitySettings()
        refreshPermissions()
    }

    func choose(_ entry: ClipboardEntry, copyOnly: Bool = false) {
        guard monitor.restore(entry) else {
            message = monitor.notice ?? "This item couldn’t be copied. Try copying it from its source again."
            return
        }
        if isDemo {
            message = "Preview item selected. The system clipboard is unchanged."
            return
        }
        let target = previousApplication
        refreshPermissions()
        if directPaste && !copyOnly && !accessibilityGranted {
            message = "Copied. Press ⌘V to paste, or enable direct paste in Settings."
            dismissHistory?()
            target?.activate(options: [.activateIgnoringOtherApps])
            return
        }
        dismissHistory?()
        guard directPaste && !copyOnly else {
            target?.activate(options: [.activateIgnoringOtherApps])
            return
        }
        guard let target, !target.isTerminated else {
            message = "Copied. Switch to an app and press ⌘V."
            return
        }
        pasteService.paste(into: target) { [weak self] succeeded in
            if !succeeded {
                self?.message = "Copied, but the app couldn’t receive a paste. Press ⌘V in the destination app."
                self?.showHistory?()
            }
        }
    }

    func clearRecent() {
        store.clearUnpinned()
        message = "Recent history cleared. Pinned items are kept."
    }

    private func seedDemo() {
        let samples: [(String, String)] = [
            ("Make something worth keeping.", "Notes"),
            ("https://developer.apple.com/design/", "Safari"),
            ("The details are not the details. They make the design.", "Safari"),
            ("Meeting notes\n• Review the first prototype\n• Share feedback on Friday\n• Keep the interaction simple", "Notes"),
            ("hello@studio.example", "Mail"),
            ("A little less searching. A little more doing.", "TextEdit")
        ]
        for (text, source) in samples.reversed() {
            store.insert(ClipboardEntry(sourceApp: source, items: [ClipboardItem(representations: [ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))])]))
        }
        if let first = store.entries.first { store.togglePin(id: first.id) }
    }
}
