import Combine
import Darwin
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
            let attributes = try fileManager.attributesOfItem(atPath: historyURL.path)
            let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? UInt64.max
            // Includes every valid v1 archive, with bounded metadata overhead.
            guard byteCount <= UInt64(Self.maximumHistoryBytes + 4 * 1_024 * 1_024) else {
                throw HistoryError.invalidArchive
            }
            let data = try Data(contentsOf: historyURL, options: .mappedIfSafe)
            let archive = try PropertyListDecoder().decode(HistoryArchive.self, from: data)
            guard archive.version == 1 || archive.version == 2 else {
                throw HistoryError.unsupportedVersion
            }
            let savedCapacity: Int
            if archive.version == 1 {
                savedCapacity = Self.defaultCapacity
            } else if let value = archive.capacity, (Self.minimumCapacity...Self.maximumCapacity).contains(value) {
                savedCapacity = value
            } else {
                throw HistoryError.invalidArchive
            }
            // Validate the archive rather than silently accepting a partially damaged history.
            guard archive.entries.count <= savedCapacity,
                  archive.entries.reduce(0, { $0 + $1.byteCount }) <= historyByteLimit,
                  archive.entries.allSatisfy({ !$0.items.isEmpty && $0.byteCount <= Self.maximumEntryBytes && $0.items.allSatisfy({ !$0.representations.isEmpty }) }) else {
                throw HistoryError.invalidArchive
            }
            capacity = savedCapacity
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
    let capacity: Int?
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
        let capacity: Int
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

    func submit(entries: [ClipboardEntry], capacity: Int, generation: Int) {
        lock.lock()
        pending = Snapshot(entries: entries, capacity: capacity, generation: generation)
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

    func removeOrphanedTemporaryFiles() throws {
        try queue.sync { try HistoryTemporaryFiles.removeOrphans(in: directory, fileManager: fileManager) }
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
                try persist(snapshot.entries, capacity: snapshot.capacity)
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

    private func persist(_ entries: [ClipboardEntry], capacity: Int) throws {
        let historyURL = directory.appendingPathComponent("history.plist")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // A crash can bypass the previous process's defer. Remove those snapshots
        // before saving, including when Clear replaces the canonical history.
        try HistoryTemporaryFiles.removeOrphans(in: directory, fileManager: fileManager)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(HistoryArchive(version: 2, capacity: capacity, entries: entries))
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

private enum HistoryTemporaryFiles {
    static func removeOrphans(in directory: URL, fileManager: FileManager) throws {
        // Pin the directory so path replacement cannot redirect deletion. Never
        // follow a symbolic link or recursively delete a directory masquerading
        // as one of our temporary files.
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw posixError()
        }
        defer { close(descriptor) }
        var directoryInfo = stat()
        guard fstat(descriptor, &directoryInfo) == 0 else { throw posixError() }
        guard directoryInfo.st_uid == getuid() else { throw POSIXError(.EPERM) }

        for name in try fileManager.contentsOfDirectory(atPath: directory.path) {
            guard name.hasPrefix(".history-"), name.hasSuffix(".tmp") else { continue }
            let identifier = String(name.dropFirst(".history-".count).dropLast(".tmp".count))
            guard UUID(uuidString: identifier)?.uuidString == identifier else { continue }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw posixError()
            }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid() else { continue }
            guard unlinkat(descriptor, name, 0) == 0 || errno == ENOENT else { throw posixError() }
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
