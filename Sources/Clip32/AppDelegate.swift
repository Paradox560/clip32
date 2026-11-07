import AppKit
import SwiftUI

final class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var panel: HistoryPanel!
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var installWindow: NSWindow?
    private var keyMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var lastExternalApplication: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let demo = CommandLine.arguments.contains("--demo")
        if demo, let flag = CommandLine.arguments.firstIndex(of: "--appearance"), CommandLine.arguments.count > flag + 1 {
            NSApp.appearance = NSAppearance(named: CommandLine.arguments[flag + 1] == "light" ? .aqua : .darkAqua)
        }
        let bundlePath = Bundle.main.bundlePath
        if !demo && (bundlePath.hasPrefix("/Volumes/") || bundlePath.contains("/AppTranslocation/")) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 330), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Install Clip32"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: InstallLocationView())
            window.center()
            installWindow = window
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        if !demo, let bundleID = Bundle.main.bundleIdentifier {
            let peers = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            for peer in peers {
                let path = peer.bundleURL?.path ?? ""
                if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") {
                    // A disk-image installation guide must not block the installed copy.
                    _ = peer.terminate()
                } else {
                    peer.activate(options: [.activateIgnoringOtherApps])
                    NSApp.terminate(nil)
                    return
                }
            }
        }
        model = AppModel(demo: demo)
        model.showHistory = { [weak self] in self?.toggleHistory() }
        model.dismissHistory = { [weak self] in self?.panel.orderOut(nil) }
        model.showSettings = { [weak self] in self?.openSettings() }
        model.showSetup = { [weak self] in self?.openSetup() }
        lastExternalApplication = NSWorkspace.shared.frontmostApplication
        buildApplicationMenu()
        buildMenuBar()
        buildPanel()
        installEventHandlers()
        model.start()
        if !demo, let flag = CommandLine.arguments.firstIndex(of: "--startup-report"), CommandLine.arguments.count > flag + 1 {
            let report: [String: Any] = [
                "bundlePath": Bundle.main.bundlePath,
                "shortcut": model.shortcut.displayName,
                "shortcutRegistered": model.shortcutActive,
                "launchAtLogin": model.login.isEnabled,
                "loginRequiresApproval": model.login.requiresApproval,
                "accessibilityGranted": model.accessibilityGranted,
                "startupMessage": model.message ?? ""
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]), options: .atomic)
            }
        }
        let defaults = UserDefaults.standard
        if demo { showHistory() }
        else if !defaults.bool(forKey: "hasShownWelcome") { openSetup() }
        if demo, let flag = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > flag + 1 {
            let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.renderPreview(to: folder)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.monitor.stop()
        model?.store.flush()
        model?.hotKey.unregister()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let installWindow { installWindow.makeKeyAndOrderFront(nil); return true }
        if let setupWindow, setupWindow.isVisible { setupWindow.makeKeyAndOrderFront(nil); return true }
        showHistory()
        return true
    }

    private func buildMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clip32 clipboard history")
        button.image?.isTemplate = true
        button.toolTip = "Clip32 — clipboard history"
        button.target = self
        button.action = #selector(statusClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func buildApplicationMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        let setup = NSMenuItem(title: "Setup Guide…", action: #selector(menuSetup), keyEquivalent: "")
        setup.target = self
        appMenu.addItem(setup)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Clip32", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    private func buildPanel() {
        panel = HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "Clip32"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: HistoryView(model: model, store: model.store, monitor: model.monitor))
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 12
        panel.contentView?.layer?.masksToBounds = true
    }

    private func installEventHandlers() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.model.handleHistoryKey?(event) == true ? nil : event
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            Task { @MainActor [weak self] in
                guard let self, let app = NSRunningApplication(processIdentifier: pid) else { return }
                if app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    self.lastExternalApplication = app
                    self.panel.orderOut(nil)
                } else {
                    self.model.refreshPermissions()
                }
            }
        }
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Open clipboard history", action: #selector(menuShowHistory), keyEquivalent: "")
            menu.addItem(withTitle: model.monitor.isPaused ? "Resume capture" : "Pause capture", action: #selector(togglePause), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
            menu.addItem(withTitle: "Setup Guide…", action: #selector(menuSetup), keyEquivalent: "")
            menu.addItem(withTitle: "Quit Clip32", action: #selector(quit), keyEquivalent: "q")
            menu.items.forEach { $0.target = self }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else { toggleHistory() }
    }

    @objc private func menuShowHistory() { showHistory() }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuSetup() { openSetup() }
    @objc private func togglePause() { model.monitor.isPaused.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func toggleHistory() {
        if panel.isVisible && panel.isKeyWindow {
            panel.orderOut(nil)
            model.previousApplication?.activate(options: [.activateIgnoringOtherApps])
        } else { showHistory() }
    }

    private func showHistory() {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            model.previousApplication = front
        } else {
            model.previousApplication = lastExternalApplication
        }
        model.refreshPermissions()
        model.presentationID = UUID()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        if let screen {
            let frame = screen.visibleFrame
            let height = min(640, frame.height - 32)
            panel.setContentSize(NSSize(width: 430, height: height))
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2 + min(60, (frame.height - panel.frame.height) / 2)))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func openSettings() {
        panel.orderOut(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 685), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Clip32 Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            settingsWindow = window
        }
        model.refreshPermissions()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func openSetup() {
        panel.orderOut(nil)
        settingsWindow?.orderOut(nil)
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 550), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Welcome to Clip32"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SetupView(model: model) { [weak self] in
                guard let self else { return }
                if !self.model.isDemo { UserDefaults.standard.set(true, forKey: "hasShownWelcome") }
                self.setupWindow?.orderOut(nil)
                self.showHistory()
            })
            window.center()
            setupWindow = window
        }
        model.refreshPermissions()
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        panel.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === installWindow { NSApp.terminate(nil) }
    }

    private func renderPreview(to folder: URL) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try render(panel.contentView, to: folder.appendingPathComponent("history.png"))
            openSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                do {
                    try self.render(self.settingsWindow?.contentView, to: folder.appendingPathComponent("settings.png"))
                    self.openSetup()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        do { try self.render(self.setupWindow?.contentView, to: folder.appendingPathComponent("setup.png")) }
                        catch { fputs("Setup preview failed: \(error)\n", stderr) }
                        print("Rendered history.png, settings.png, and setup.png")
                        NSApp.terminate(nil)
                    }
                } catch {
                    fputs("Preview failed: \(error)\n", stderr)
                    NSApp.terminate(nil)
                }
            }
        } catch {
            fputs("Preview failed: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    private func render(_ view: NSView?, to url: URL) throws {
        guard let view, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }
}
