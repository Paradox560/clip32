import Combine
import Foundation

@MainActor
public final class HistoryStore: ObservableObject {
    public static let defaultCapacity = 32
    public static let minimumCapacity = 1
    public static let maximumCapacity = 256
    public static let maximumEntryBytes = 16 * 1_024 * 1_024
    /// The original 32 × 16 MiB maximum also bounds larger, configurable histories.
    public static let maximumHistoryBytes = 512 * 1_024 * 1_024

    @Published public private(set) var entries: [ClipboardEntry] = []
    @Published public private(set) var capacity = HistoryStore.defaultCapacity
    @Published public private(set) var errorMessage: String?

    public var totalBytes: Int { entries.reduce(0) { $0 + $1.byteCount } }

    public let directory: URL
    public var historyURL: URL { directory.appendingPathComponent("history.plist") }

    private let fileManager: FileManager
    private let historyByteLimit: Int
    private var canPersist = true
    private var generation = 0
    private lazy var writer = HistoryPersistenceWriter(directory: directory, fileManager: fileManager) { [weak self] result in
        Task { @MainActor [weak self] in self?.finishSave(result) }
    }

    public convenience init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.init(directory: directory, fileManager: fileManager, historyByteLimit: Self.maximumHistoryBytes)
    }

    /// An internal budget override keeps boundary tests small and deterministic.
    init(directory: URL?, fileManager: FileManager, historyByteLimit: Int) {
        self.fileManager = fileManager
        self.historyByteLimit = max(1, min(historyByteLimit, Self.maximumHistoryBytes))
        self.directory = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clip32", isDirectory: true)
        do {
            try writer.removeOrphanedTemporaryFiles()
        } catch {
            errorMessage = "Temporary history from an interrupted save could not be removed: \(error.localizedDescription)"
        }
        load()
    }

    /// Pinned items must be explicitly unpinned before lowering the limit past them.
    @discardableResult
    public func setCapacity(_ requestedCapacity: Int) -> Bool {
        guard (Self.minimumCapacity...Self.maximumCapacity).contains(requestedCapacity) else {
            reportValidationError("Choose a history size from \(Self.minimumCapacity) to \(Self.maximumCapacity) items.")
            return false
        }
        let pinnedCount = entries.filter(\.isPinned).count
        guard requestedCapacity >= pinnedCount else {
            reportValidationError("You have \(pinnedCount) pinned items. Unpin or delete some before lowering the history size to \(requestedCapacity).")
            return false
        }
        var updatedEntries = entries
        while updatedEntries.count > requestedCapacity {
            guard let index = updatedEntries.indices.reversed().first(where: { !updatedEntries[$0].isPinned }) else { return false }
            updatedEntries.remove(at: index)
        }
        capacity = requestedCapacity
        entries = updatedEntries
        save()
        return true
    }

    @discardableResult
    public func insert(_ entry: ClipboardEntry) -> Bool {
        guard !entry.items.isEmpty, entry.items.allSatisfy({ !$0.representations.isEmpty }) else { return false }
        guard entry.byteCount <= Self.maximumEntryBytes else {
            reportValidationError("This item is larger than 16 MB and was not saved. Your current clipboard is unchanged.")
            return false
        }
        let matchingEntry = entries.first(where: { $0.hasSameContent(as: entry) })
        var newestEntry = entry
        if let matchingEntry {
            newestEntry.id = matchingEntry.id
            newestEntry.isPinned = matchingEntry.isPinned
        } else if entries.contains(where: { $0.id == newestEntry.id }) {
            // Caller-supplied UUIDs must not alias two different payloads.
            newestEntry.id = UUID()
        }
        var updatedEntries = entries.filter { !$0.hasSameContent(as: entry) }
        var updatedBytes = updatedEntries.reduce(0) { $0 + $1.byteCount }
        while updatedEntries.count >= capacity || updatedBytes + newestEntry.byteCount > historyByteLimit {
            guard let index = updatedEntries.indices.reversed().first(where: { !updatedEntries[$0].isPinned }) else {
                if updatedEntries.count >= capacity {
                    reportValidationError("All \(capacity) entries are pinned. Unpin or delete an entry to save new copies.")
                } else {
                    reportValidationError("This copy cannot fit within the 512 MB history budget without removing pinned items. Unpin or delete an item to make room.")
                }
                return false
            }
            updatedBytes -= updatedEntries.remove(at: index).byteCount
        }
        updatedEntries.insert(newestEntry, at: 0)
        entries = updatedEntries
        save()
        return true
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    public func clear() {
        // Clearing is an explicit user action and may replace an unreadable archive.
        canPersist = true
        entries = []
        save()
    }

    public func clearUnpinned() {
        entries.removeAll { !$0.isPinned }
        save()
    }

    public func togglePin(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isPinned.toggle()
        save()
    }

    /// Wait for pending disk work before quitting or reopening the store in a test.
    /// Normal copying never waits for disk I/O on the main thread.
    public func flush() {
        if let result = writer.flush() { finishSave(result) }
    }

    private func load() {
        guard fileManager.fileExists(atPath: historyURL.path) else { return }
        do {
            let loaded = try writer.load(historyByteLimit: historyByteLimit)
            capacity = loaded.capacity
            entries = loaded.entries
            // Payloads are committed before the manifest replaces the legacy file.
            // Migration is queued so startup does not wait for its disk writes.
            if loaded.needsMigration { save() }
        } catch {
            canPersist = false
            errorMessage = "Saved history could not be opened. New copies will be kept only for this session. The saved file is untouched. Clear history to reset it. (\(error.localizedDescription))"
        }
    }

    private func save() {
        guard canPersist else { return }
        generation += 1
        writer.submit(entries: entries, capacity: capacity, generation: generation)
    }

    private func reportValidationError(_ message: String) {
        generation += 1
        errorMessage = message
    }

    private func finishSave(_ result: HistoryPersistenceWriter.WriteResult) {
        guard result.generation == generation else { return }
        errorMessage = result.errorMessage
    }

}
