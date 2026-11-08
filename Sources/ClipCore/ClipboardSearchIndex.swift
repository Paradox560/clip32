import Foundation

public enum ClipboardHistoryFilter: String, CaseIterable, Sendable {
    case all = "All", text = "Text", images = "Images", files = "Files", pinned = "Pinned"

    public func includes(_ entry: ClipboardEntry) -> Bool {
        switch self {
        case .all: return true
        case .text: return entry.kind == .text
        case .images: return entry.kind == .image
        case .files: return entry.kind == .files
        case .pinned: return entry.isPinned
        }
    }
}

/// Confine an index to one queue. Parsed text is disposable, never persisted,
/// and bounded independently of the saved clipboard's payload budget.
public final class ClipboardSearchIndex {
    private struct CachedText {
        let items: [ClipboardItem]
        let text: String
        let byteCount: Int
        var lastUse: UInt64
    }

    public let maximumCachedBytes: Int
    public private(set) var cachedByteCount = 0
    public var cachedEntryCount: Int { cache.count }
    private var cache: [UUID: CachedText] = [:]
    private var clock: UInt64 = 0
    private let extractText: (ClipboardEntry) -> String

    public init(maximumCachedBytes: Int = 32 * 1_024 * 1_024,
                extractText: @escaping (ClipboardEntry) -> String = { $0.searchableText }) {
        self.maximumCachedBytes = max(0, maximumCachedBytes)
        self.extractText = extractText
    }

    /// Drop removed or changed payloads promptly. Pinning, ordering, timestamps,
    /// and source-app metadata do not invalidate the extracted text.
    public func synchronize(with entries: [ClipboardEntry]) {
        let current = Dictionary(entries.map { ($0.id, $0.items) }, uniquingKeysWith: { _, new in new })
        for (id, saved) in cache where current[id] != saved.items { remove(id) }
    }

    /// A nil result means a superseded request was cancelled. Checks between
    /// entries keep rapid query changes from building a long backlog of scans.
    public func search(_ entries: [ClipboardEntry], query: String, filter: ClipboardHistoryFilter,
                       isCancelled: () -> Bool = { false }) -> [ClipboardEntry]? {
        guard !isCancelled() else { return nil }
        synchronize(with: entries)
        var result: [ClipboardEntry] = []
        for entry in entries {
            guard !isCancelled() else { return nil }
            guard filter.includes(entry) else { continue }
            let matches = autoreleasepool { query.isEmpty || text(for: entry).localizedCaseInsensitiveContains(query) }
            if matches { result.append(entry) }
        }
        return isCancelled() ? nil : result
    }

    private func text(for entry: ClipboardEntry) -> String {
        clock &+= 1
        if var saved = cache[entry.id], saved.items == entry.items {
            saved.lastUse = clock
            cache[entry.id] = saved
            return saved.text
        }
        remove(entry.id)
        let text = extractText(entry)
        // Count UTF-8 storage plus UTF-16 storage conservatively for bridged
        // Foundation strings. A large result is searched fully but not retained.
        let cost = text.utf8.count + text.utf16.count * 2
        guard maximumCachedBytes > 0, cost <= maximumCachedBytes else { return text }
        while cachedByteCount + cost > maximumCachedBytes || cache.count >= 256 {
            guard let oldest = cache.min(by: { $0.value.lastUse < $1.value.lastUse })?.key else { break }
            remove(oldest)
        }
        cache[entry.id] = CachedText(items: entry.items, text: text, byteCount: cost, lastUse: clock)
        cachedByteCount += cost
        return text
    }

    private func remove(_ id: UUID) {
        if let removed = cache.removeValue(forKey: id) { cachedByteCount -= removed.byteCount }
    }
}

public struct ClipboardPresentation: Equatable {
    public let title: String
    public let preview: String
    public let kind: ClipboardEntry.Kind

    public init(title: String, preview: String, kind: ClipboardEntry.Kind) {
        self.title = title
        self.preview = preview
        self.kind = kind
    }
}

/// Separate from search so showing a row never decodes a full plain-text copy.
/// RTF title/preview import occurs once per cached payload, not on each hover,
/// selection, accessibility label, or relative-date update.
public final class ClipboardPresentationCache {
    private struct CachedPresentation {
        let items: [ClipboardItem]
        let value: ClipboardPresentation
        let byteCount: Int
        var lastUse: UInt64
    }

    public let maximumCachedBytes: Int
    public private(set) var cachedByteCount = 0
    public var cachedEntryCount: Int { cache.count }
    private var cache: [UUID: CachedPresentation] = [:]
    private var clock: UInt64 = 0
    private let present: (ClipboardEntry) -> ClipboardPresentation

    public init(maximumCachedBytes: Int = 2 * 1_024 * 1_024,
                present: @escaping (ClipboardEntry) -> ClipboardPresentation = {
                    let text = $0.displayText
                    return ClipboardPresentation(title: text.title, preview: text.preview, kind: $0.kind)
                }) {
        self.maximumCachedBytes = max(0, maximumCachedBytes)
        self.present = present
    }

    public func synchronize(with entries: [ClipboardEntry]) {
        let current = Dictionary(entries.map { ($0.id, $0.items) }, uniquingKeysWith: { _, new in new })
        for (id, saved) in cache where current[id] != saved.items { remove(id) }
    }

    public func presentation(for entry: ClipboardEntry) -> ClipboardPresentation {
        clock &+= 1
        if var saved = cache[entry.id], saved.items == entry.items {
            saved.lastUse = clock
            cache[entry.id] = saved
            return saved.value
        }
        remove(entry.id)
        let value = present(entry)
        let cost = value.title.utf8.count + value.preview.utf8.count
            + (value.title.utf16.count + value.preview.utf16.count) * 2
        guard maximumCachedBytes > 0, cost <= maximumCachedBytes else { return value }
        while cachedByteCount + cost > maximumCachedBytes || cache.count >= 256 {
            guard let oldest = cache.min(by: { $0.value.lastUse < $1.value.lastUse })?.key else { break }
            remove(oldest)
        }
        cache[entry.id] = CachedPresentation(items: entry.items, value: value, byteCount: cost, lastUse: clock)
        cachedByteCount += cost
        return value
    }

    private func remove(_ id: UUID) {
        if let removed = cache.removeValue(forKey: id) { cachedByteCount -= removed.byteCount }
    }
}
