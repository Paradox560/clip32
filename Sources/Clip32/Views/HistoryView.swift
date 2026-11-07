import AppKit
import SwiftUI
import ClipCore
import ImageIO

private enum HistoryFilter: String, CaseIterable {
    case all = "All", text = "Text", images = "Images", files = "Files", pinned = "Pinned"
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: HistoryStore
    @ObservedObject var monitor: ClipboardMonitor
    @State private var query = ""
    @State private var filter: HistoryFilter = .all
    @State private var selected: UUID?
    @FocusState private var searchFocused: Bool

    private var entries: [ClipboardEntry] {
        store.entries.filter { entry in
            let matchesType: Bool
            switch filter {
            case .all: matchesType = true
            case .text: matchesType = entry.kind == .text
            case .images: matchesType = entry.kind == .image
            case .files: matchesType = entry.kind == .files
            case .pinned: matchesType = entry.isPinned
            }
            return matchesType && (query.isEmpty || entry.searchableText.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PaperClipMark().frame(width: 44, height: 44).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clip32").font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("A little more at your fingertips.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.shortcut.displayName).font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 5)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                Button { model.showSettings?() } label: {
                    Image(systemName: "gearshape").font(.system(size: 15)).frame(width: 26, height: 28)
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("Settings").accessibilityLabel("Settings")
            }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 18)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your clipboard", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
                    .accessibilityLabel("Search clipboard history")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }.padding(11).background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.06)))
                .padding(.horizontal, 20)

            HStack(spacing: 4) {
                ForEach(HistoryFilter.allCases, id: \.self) { item in
                    Button {
                        filter = item
                        selected = entries.first?.id
                    } label: {
                        HStack(spacing: 4) {
                            if item == .pinned { Image(systemName: "pin.fill").font(.system(size: 9)) }
                            Text(item.rawValue).font(.system(size: 11, weight: filter == item ? .semibold : .medium))
                        }.padding(.horizontal, 10).padding(.vertical, 6)
                            .background(filter == item ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(filter == item ? Color.accentColor : .secondary)
                    }.buttonStyle(.plain).accessibilityAddTraits(filter == item ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 12)

            if model.directPaste && !model.accessibilityGranted && !model.isDemo {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "cursorarrow.click").foregroundStyle(Color.accentColor).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("One step to direct paste").font(.system(size: 12, weight: .semibold))
                        Text("Allow Clip32 in Accessibility to paste into your previous app.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Enable direct paste…") { model.enableAccessibility() }.buttonStyle(.link).font(.system(size: 11, weight: .medium))
                    }
                    Spacer(minLength: 0)
                }.padding(12).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }

            HStack {
                Text(filter == .pinned ? "PINNED" : "CLIPBOARD HISTORY").font(.system(size: 9, weight: .semibold)).tracking(0.9)
                Text("\(store.entries.count) / \(store.capacity)").font(.system(size: 10, design: .monospaced))
                Spacer()
                Menu {
                    Button("Clear recent history") { model.clearRecent() }.disabled(store.entries.allSatisfy(\.isPinned))
                    Button(monitor.isPaused ? "Resume capture" : "Pause capture") { monitor.isPaused.toggle() }
                    Divider()
                    Button("Settings…") { model.showSettings?() }
                    Button("Quit Clip32") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 16) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("History actions").accessibilityLabel("History actions")
            }.foregroundStyle(.secondary).padding(.horizontal, 22).padding(.bottom, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    if entries.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: query.isEmpty ? "doc.on.clipboard" : "magnifyingglass").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                            Text(emptyTitle).font(.system(size: 15, weight: .medium))
                            Text(emptyDescription).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 260)
                        }.frame(maxWidth: .infinity).padding(.vertical, 65)
                    } else {
                        LazyVStack(spacing: 5) {
                            ForEach(entries) { entry in
                                HistoryRow(entry: entry, selected: entry.id == selected,
                                    choose: { model.choose(entry) },
                                    copy: { model.choose(entry, copyOnly: true) },
                                    pin: { store.togglePin(id: entry.id) },
                                    delete: { store.remove(id: entry.id) })
                                    .id(entry.id)
                            }
                        }.padding(.horizontal, 12).padding(.vertical, 3)
                    }
                }
                .onChange(of: selected) { id in if let id { proxy.scrollTo(id) } }
            }

            if let message = store.errorMessage ?? monitor.notice ?? model.message {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "info.circle")
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if model.message != nil {
                        Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(12).background(.quaternary.opacity(0.3))
            }

            Divider().opacity(0.5)
            HStack(spacing: 5) {
                Circle().fill(monitor.isPaused ? Color.orange : Color.green).frame(width: 5, height: 5)
                Text(monitor.isPaused ? "Paused" : "Ready when you copy").font(.system(size: 10))
                Spacer()
                Text("↑↓ select").font(.system(size: 10))
                Text("↵ \(model.directPaste && model.accessibilityGranted ? "paste" : "copy")").font(.system(size: 10)).padding(.leading, 7)
                Text("esc close").font(.system(size: 10)).padding(.leading, 7)
            }.foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(PanelMaterial())
        .tint(ClipTheme.accent)
        .accentColor(ClipTheme.accent)
        .onAppear { model.handleHistoryKey = handleKey }
        .onReceive(model.$presentationID) { _ in
            query = ""
            filter = .all
            selected = store.entries.first?.id
            searchFocused = true
        }
        .onChange(of: query) { _ in selected = entries.first?.id }
        .onChange(of: store.entries) { _ in
            if !entries.contains(where: { $0.id == selected }) { selected = entries.first?.id }
        }
    }

    private var emptyTitle: String {
        if !query.isEmpty { return "No matching clips" }
        return filter == .pinned ? "Keep your favorites close" : "Your next copy starts here"
    }
    private var emptyDescription: String {
        if !query.isEmpty { return "Try another word or switch to All." }
        if filter == .pinned { return "Pin an item from its menu to keep it in your history." }
        return "Copy text, an image, or a file with ⌘C. Your last \(store.capacity) items will be right here."
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { model.dismissHistory?(); model.previousApplication?.activate(options: [.activateIgnoringOtherApps]); return true }
        if modifiers.contains(.command), event.charactersIgnoringModifiers == "," { model.showSettings?(); return true }
        if modifiers.contains(.command), event.charactersIgnoringModifiers == "f" { searchFocused = true; return true }
        if modifiers.contains(.command), event.keyCode == 51, let selected { store.remove(id: selected); return true }
        if modifiers.contains(.command), event.charactersIgnoringModifiers == "p", let selected { store.togglePin(id: selected); return true }
        if modifiers.contains(.command), let key = event.charactersIgnoringModifiers, let number = Int(key), (1...9).contains(number), entries.count >= number {
            model.choose(entries[number - 1]); return true
        }
        guard !modifiers.contains(.command), !modifiers.contains(.control), !modifiers.contains(.option) else { return false }
        if event.keyCode == 125 || event.keyCode == 126 {
            guard !entries.isEmpty else { return true }
            let current = entries.firstIndex(where: { $0.id == selected }) ?? 0
            let next = min(max(current + (event.keyCode == 125 ? 1 : -1), 0), entries.count - 1)
            selected = entries[next].id
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76, let entry = entries.first(where: { $0.id == selected }) {
            model.choose(entry); return true
        }
        return false
    }
}

private struct HistoryRow: View {
    let entry: ClipboardEntry
    let selected: Bool
    let choose: () -> Void
    let copy: () -> Void
    let pin: () -> Void
    let delete: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: choose) {
                HStack(alignment: .top, spacing: 11) {
                    Group {
                        if let image = ThumbnailCache.shared.image(for: entry) {
                            Image(nsImage: image).resizable().scaledToFill().frame(width: 34, height: 38).clipped().clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Color.accentColor.opacity(0.75)).frame(width: 34, height: 38)
                                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }.accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 5) {
                            if entry.isPinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(Color.accentColor) }
                            Text(entry.sourceApp ?? kindLabel).lineLimit(1)
                            Text("·")
                            Text(entry.createdAt, style: .relative).lineLimit(1)
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(.top, 2)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(entry.isPinned ? "Pinned, " : "")\(entry.title). Select clipboard item.")
            Menu {
                Button("Paste", action: choose)
                Button("Copy without pasting", action: copy)
                Divider()
                Button(entry.isPinned ? "Unpin" : "Pin", action: pin)
                Button("Delete", role: .destructive, action: delete)
            } label: { Image(systemName: "ellipsis").frame(width: 18, height: 22) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
                .opacity(hovered || selected || entry.isPinned ? 1 : 0.45).accessibilityLabel("Actions for \(entry.title)")
        }
        .padding(.horizontal, 10).padding(.vertical, 11)
        .background(selected ? Color.accentColor.opacity(0.10) : hovered ? Color.primary.opacity(0.035) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor.opacity(0.15) : .clear))
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Copy without pasting", action: copy)
            Button(entry.isPinned ? "Unpin" : "Pin", action: pin)
            Button("Delete", role: .destructive, action: delete)
        }
        .help(entry.preview)
    }

    private var icon: String { entry.kind == .image ? "photo" : entry.kind == .files ? "doc" : "text.alignleft" }
    private var kindLabel: String { entry.kind == .image ? "Image" : entry.kind == .files ? "Files" : "Text" }
}

private struct PanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() { cache.countLimit = 32 }
    func image(for entry: ClipboardEntry) -> NSImage? {
        guard entry.kind == .image else { return nil }
        let key = entry.id.uuidString as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let data = entry.imageData,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 160, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key)
        return image
    }
}
