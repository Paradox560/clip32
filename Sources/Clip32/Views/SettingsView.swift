import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmClear = false
    private let permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 27, weight: .medium)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Make yourself at home.").font(.system(size: 21, weight: .semibold))
                    Text("Clip32 stays in your menu bar, ready when you need it.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(24)

            Form {
                Section("General") {
                    Picker("Open clipboard history", selection: Binding(get: { model.shortcut }, set: { model.changeShortcut($0) })) {
                        ForEach(HotKeyChoice.allCases) { choice in Text(choice.displayName).tag(choice) }
                    }
                    Toggle("Launch at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                    HStack {
                        Text(model.loginStatus).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if model.login.requiresApproval {
                            Button("Open Login Items…") { model.login.openSettings() }.font(.caption)
                        }
                    }
                }
                Section("Pasting") {
                    Toggle("Paste directly into the previous app", isOn: $model.directPaste)
                    HStack(alignment: .top) {
                        Image(systemName: model.accessibilityGranted ? "checkmark.circle.fill" : "hand.raised")
                            .foregroundStyle(model.accessibilityGranted ? Color.green : .secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.accessibilityGranted ? "Accessibility access is enabled" : "Allow Clip32 in System Settings → Privacy & Security → Accessibility.")
                            if !model.accessibilityGranted {
                                Button("Enable direct paste…") { model.enableAccessibility() }
                            }
                            Text("Without direct paste, selecting an item copies it. Press ⌘V to paste.").foregroundStyle(.secondary)
                        }
                    }.font(.caption)
                }
                Section("History") {
                    LabeledContent("Capacity", value: "32 items, including pins")
                    Text("Text, images, and file references are saved on this Mac and kept after a restart. Pinned items stay until you unpin or delete them.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Items over 16 MB and items marked as confidential by their source app are skipped. Other copied text may include sensitive information.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Clear recent history") { model.clearRecent() }
                        Button("Delete all history…", role: .destructive) { confirmClear = true }
                    }
                }
                Section("Keyboard") {
                    LabeledContent("Move through history", value: "↑ / ↓")
                    LabeledContent("Paste selected item", value: "Return")
                    LabeledContent("Paste one of the first nine items", value: "⌘1 – ⌘9")
                    LabeledContent("Pin / unpin selected item", value: "⌘P")
                    LabeledContent("Delete selected item", value: "⌘⌫")
                    LabeledContent("Close history", value: "Esc")
                }
            }.formStyle(.grouped)

            if let message = model.message ?? model.store.errorMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24).padding(.top, 8)
            }

            HStack {
                Text("Clip32 1.0 · Stored locally · No cloud sync").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Quit Clip32") { NSApp.terminate(nil) }.controlSize(.small)
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 490, height: 685)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(ClipTheme.accent)
        .accentColor(ClipTheme.accent)
        .onReceive(permissionTimer) { _ in model.refreshPermissions() }
        .onAppear { model.refreshPermissions() }
        .alert("Delete all clipboard history?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Delete everything", role: .destructive) { model.store.clear(); model.message = "All saved history deleted." }
        } message: { Text("This also deletes pinned items from Clip32. Your current system clipboard and original files are unchanged.") }
    }
}
