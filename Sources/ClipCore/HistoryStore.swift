import Combine
import Foundation

@MainActor
public final class HistoryStore: ObservableObject {
    public static let capacity = 32
    public static let maximumEntryBytes = 16 * 1_024 * 1_024

    @Published public private(set) var entries: [ClipboardEntry] = []
    @Published public private(set) var errorMessage: String?

    public let directory: URL
    public var historyURL: URL { directory.appendingPathComponent("history.plist") }

    private let fileManager: FileManager
    private var canPersist = true
    private var generation = 0
    private lazy var writer = HistoryPersistenceWriter(directory: directory, fileManager: fileManager) { [weak self] result in
        Task { @MainActor [weak self] in self?.finishSave(result) }
    }

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clip32", isDirectory: true)
        load()
    }

    @discardableResult
    public func insert(_ entry: ClipboardEntry) -> Bool {
        guard !entry.items.isEmpty, entry.items.allSatisfy({ !$0.representations.isEmpty }) else { return false }
        guard entry.byteCount <= Self.maximumEntryBytes else {
            generation += 1
            errorMessage = "This item is larger than 16 MB and was not saved. Your current clipboard is unchanged."
            return false
        }
        let matchingEntry = entries.first(where: { $0.hasSameContent(as: entry) })
        guard matchingEntry != nil || entries.count < Self.capacity || entries.contains(where: { !$0.isPinned }) else {
            generation += 1
            errorMessage = "All 32 entries are pinned. Unpin or delete an entry to save new copies."
            return false
        }
        var newestEntry = entry
        if let matchingEntry {
            newestEntry.id = matchingEntry.id
            newestEntry.isPinned = matchingEntry.isPinned
        }
        var updatedEntries = entries.filter { !$0.hasSameContent(as: entry) }
        while updatedEntries.count >= Self.capacity {
            guard let index = updatedEntries.indices.reversed().first(where: { !updatedEntries[$0].isPinned }) else { return false }
            updatedEntries.remove(at: index)
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
            let attributes = try fileManager.attributesOfItem(atPath: historyURL.path)
            let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? UInt64.max
            // Allow bounded metadata overhead in addition to the 32 payloads.
            guard byteCount <= UInt64(Self.capacity * Self.maximumEntryBytes + 4 * 1_024 * 1_024) else {
                throw HistoryError.invalidArchive
            }
            let data = try Data(contentsOf: historyURL, options: .mappedIfSafe)
            let archive = try PropertyListDecoder().decode(HistoryArchive.self, from: data)
            guard archive.version == 1 else {
                throw HistoryError.unsupportedVersion
            }
            // Validate the archive rather than silently accepting a partially damaged history.
            guard archive.entries.count <= Self.capacity,
                  archive.entries.allSatisfy({ !$0.items.isEmpty && $0.byteCount <= Self.maximumEntryBytes && $0.items.allSatisfy({ !$0.representations.isEmpty }) }) else {
                throw HistoryError.invalidArchive
            }
            entries = archive.entries
            try protectStorage()
        } catch {
            canPersist = false
            errorMessage = "Saved history could not be opened. New copies will be kept only for this session. The saved file is untouched. Clear history to reset it. (\(error.localizedDescription))"
        }
    }

    private func save() {
        guard canPersist else { return }
        generation += 1
        writer.submit(entries: entries, generation: generation)
    }

    private func finishSave(_ result: HistoryPersistenceWriter.WriteResult) {
        guard result.generation == generation else { return }
        errorMessage = result.errorMessage
    }

    private func protectStorage() throws {
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
    }

    private enum HistoryError: LocalizedError {
        case unsupportedVersion, invalidArchive

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: return "The history format is not supported by this version of Clip32."
            case .invalidArchive: return "The history file contains invalid entries."
            }
        }
    }
}

private struct HistoryArchive: Codable {
    let version: Int
    let entries: [ClipboardEntry]
}

/// All filesystem mutations use one serial queue. The lock only protects the small
/// handoff state, so incoming copies replace queued snapshots instead of accumulating.
private final class HistoryPersistenceWriter: @unchecked Sendable {
    struct WriteResult: Sendable {
        let generation: Int
        let errorMessage: String?
    }

    private struct Snapshot: Sendable {
        let entries: [ClipboardEntry]
        let generation: Int
    }

    private let directory: URL
    private let fileManager: FileManager
    private let completion: @Sendable (WriteResult) -> Void
    private let queue = DispatchQueue(label: "Clip32.history-writer", qos: .utility)
    private let lock = NSLock()
    // These three fields are accessed only while holding lock.
    private var pending: Snapshot?
    private var isScheduled = false
    private var lastResult: WriteResult?

    init(directory: URL, fileManager: FileManager, completion: @escaping @Sendable (WriteResult) -> Void) {
        self.directory = directory
        self.fileManager = fileManager
        self.completion = completion
    }

    func submit(entries: [ClipboardEntry], generation: Int) {
        lock.lock()
        pending = Snapshot(entries: entries, generation: generation)
        let needsScheduling = !isScheduled
        isScheduled = true
        lock.unlock()
        if needsScheduling { queue.async { self.drain() } }
    }

    func flush() -> WriteResult? {
        queue.sync {}
        lock.lock()
        defer { lock.unlock() }
        return lastResult
    }

    private func drain() {
        while true {
            lock.lock()
            guard let snapshot = pending else {
                isScheduled = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            let result: WriteResult
            do {
                try persist(snapshot.entries)
                result = WriteResult(generation: snapshot.generation, errorMessage: nil)
            } catch {
                result = WriteResult(generation: snapshot.generation, errorMessage: "History could not be saved and is currently kept in memory: \(error.localizedDescription)")
            }
            lock.lock()
            lastResult = result
            lock.unlock()
            completion(result)
        }
    }

    private func persist(_ entries: [ClipboardEntry]) throws {
        let historyURL = directory.appendingPathComponent("history.plist")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(HistoryArchive(version: 1, entries: entries))
        // Write through an owner-only temporary file before replacing the archive.
        let temporaryURL = directory.appendingPathComponent(".history-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        guard fileManager.createFile(atPath: temporaryURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if fileManager.fileExists(atPath: historyURL.path) {
            _ = try fileManager.replaceItemAt(historyURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: historyURL)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
    }
}
