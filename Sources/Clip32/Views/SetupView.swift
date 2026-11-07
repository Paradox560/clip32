import AppKit
import SwiftUI
import ClipCore

struct SetupView: View {
    @ObservedObject var model: AppModel
    let finish: () -> Void
    @State private var step = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PaperClipMark().frame(width: 64, height: 64).accessibilityHidden(true)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<3) { index in
                        Capsule().fill(index <= step ? ClipTheme.accent : Color.secondary.opacity(0.18)).frame(width: 24, height: 4)
                    }
                }.accessibilityLabel("Setup step \(step + 1) of 3")
            }.padding(.bottom, 26)

            Text(title).font(.system(size: 27, weight: .semibold)).padding(.bottom, 9)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 24)

            ScrollView {
                Group {
                    switch step {
                    case 0: welcome
                    case 1: preferences
                    default: ready
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 14)
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
            }
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                Button(step == 2 ? "Start using Clip32" : "Continue") {
                    if step < 2 { step += 1 } else { finish() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(30).frame(width: 490, height: 550)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(ClipTheme.accent).accentColor(ClipTheme.accent)
        .onReceive(timer) { _ in model.refreshPermissions() }
    }

    private var title: String {
        ["Your clipboard, kept close.", "Settle in. Stay ready.", "A familiar habit. More room."][step]
    }
    private var subtitle: String {
        ["A small home for the things you copy. Clip32 stays in your menu bar and brings them back when you need them.",
         "Open automatically when you log in, and choose how your saved clips return to your work.",
         "You’re ready. Copy normally, open your history, and pick up where you left off."][step]
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            feature("doc.on.doc", "Copy anything you need", "Text, images, and references to copied files.")
            feature("clock.arrow.circlepath", "Room for your recent copies", "Starts with 32 entries. Choose 1–256 in Settings and pin your favorites.")
            feature("externaldrive", "Kept on this Mac", "History stays locally on disk after a restart. No account or cloud sync.")
        }
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 17) {
            Picker("Open history", selection: Binding(get: { model.shortcut }, set: { model.changeShortcut($0) })) {
                ForEach(HotKeyChoice.allCases) { Text($0.displayName).tag($0) }
            }
            Divider()
            Toggle("Launch at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
            Text(model.loginStatus).font(.caption).foregroundStyle(.secondary)
            if model.login.requiresApproval {
                Button("Open Login Items…") { model.login.openSettings() }
            }
            Divider()
            Toggle("Paste directly into the previous app", isOn: $model.directPaste)
            if model.accessibilityGranted {
                Label("Accessibility access is enabled", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(ClipTheme.accent)
            } else if model.directPaste {
                Text("macOS needs your permission to paste. Enable Clip32 in Privacy & Security → Accessibility, then return here.").font(.caption).foregroundStyle(.secondary)
                Button("Allow direct paste…") { model.enableAccessibility() }
            }
        }.font(.system(size: 12))
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 20) {
            feature("command", "⌘C to collect", "New copies appear automatically while Clip32 is running.")
            feature("keyboard", "\(model.shortcut.displayName) to return", "Search, use ↑ and ↓ to select, then press Return.")
            feature("checkmark.circle", model.directPaste && model.accessibilityGranted ? "Choose a clip to paste it" : "Choose a clip, then press ⌘V", model.directPaste && model.accessibilityGranted ? "Clip32 returns to the app you were using." : "Direct paste can be enabled any time in Settings.")
            Text("Find settings and this guide using the clipboard icon in your menu bar.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(ClipTheme.accent).frame(width: 24, height: 25)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct InstallLocationView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaperClipMark().frame(width: 64, height: 64)
            Text("Give Clip32 a home.").font(.system(size: 25, weight: .semibold))
            Text("Drag Clip32 into the Applications folder in the disk image, then open it from Applications. This keeps launch at login and Accessibility access connected to the installed copy.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Applications") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true)) }
                Spacer()
                Button("Quit Clip32") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction)
            }.padding(.top, 10)
        }.padding(30).frame(width: 460).background(Color(nsColor: .windowBackgroundColor))
            .tint(ClipTheme.accent).accentColor(ClipTheme.accent)
    }
}
