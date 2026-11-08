import CryptoKit
import Darwin
import Foundation

/// The manifest contains ordering and mutable metadata, never clipboard bytes.
/// Payload files are immutable and appear before the manifest references them.
private struct HistoryManifest: Codable {
    let version: Int
    let capacity: Int
    let entries: [HistoryRecord]
}

private struct HistoryRecord: Codable {
    let id: UUID
    let createdAt: Date
    let sourceApp: String?
    let isPinned: Bool
    let payload: UUID
    let byteCount: Int
    let encodedBytes: Int
    let checksum: Data
}

private struct HistoryPayload: Codable {
    let version: Int
    let items: [ClipboardItem]
}

private struct LegacyHistoryArchive: Decodable {
    let version: Int
    let capacity: Int?
    let entries: [ClipboardEntry]
}

private enum HistoryDiskError: LocalizedError {
    case invalidArchive, unsupportedVersion

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "The history contains invalid or missing data."
        case .unsupportedVersion: return "The history format is not supported by this version of Clip32."
        }
    }
}

/// All filesystem mutations use one serial queue. Incoming copies replace queued
/// snapshots instead of accumulating. Only changed payloads are encoded/written.
final class HistoryPersistenceWriter: @unchecked Sendable {
    struct WriteResult: Sendable {
        let generation: Int
        let errorMessage: String?
    }

    struct LoadedHistory {
        let entries: [ClipboardEntry]
        let capacity: Int
        let needsMigration: Bool
    }

    private struct Snapshot: Sendable {
        let entries: [ClipboardEntry]
        let capacity: Int
        let generation: Int
    }

    private struct StoredPayload {
        let identifier: UUID
        let items: [ClipboardItem]
        let encodedBytes: Int
        let checksum: Data
    }

    private let directory: URL
    private let fileManager: FileManager
    private let completion: @Sendable (WriteResult) -> Void
    private let queue = DispatchQueue(label: "Clip32.history-writer", qos: .utility)
    private let lock = NSLock()
    private var pending: Snapshot?
    private var isScheduled = false
    private var lastResult: WriteResult?
    // Accessed only on queue. Data uses copy-on-write backing shared with entries.
    private var storedPayloads: [UUID: StoredPayload] = [:]

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
        try queue.sync {
            guard let files = try HistoryFiles(directory: directory, fileManager: fileManager, create: false) else { return }
            try files.removeTemporaryFiles()
            // Without a committed manifest there can be no referenced payloads.
            if try files.attributes("history.plist") == nil { try files.removeUnusedPayloads(keeping: []) }
        }
    }

    func load(historyByteLimit: Int) throws -> LoadedHistory {
        try queue.sync {
            guard let files = try HistoryFiles(directory: directory, fileManager: fileManager, create: false) else { throw HistoryDiskError.invalidArchive }
            let data = try files.read("history.plist", maximumBytes: 512 * 1_024 * 1_024 + 4 * 1_024 * 1_024)
            struct Header: Decodable { let version: Int }
            let decoder = PropertyListDecoder()
            let version = try decoder.decode(Header.self, from: data).version
            if version == 1 || version == 2 {
                let archive = try decoder.decode(LegacyHistoryArchive.self, from: data)
                let capacity = version == 1 ? 32 : archive.capacity ?? 0
                try Self.validate(archive.entries, capacity: capacity, historyByteLimit: historyByteLimit)
                try files.removeUnusedPayloads(keeping: [])
                return LoadedHistory(entries: archive.entries, capacity: capacity, needsMigration: true)
            }
            guard version == 3 else { throw HistoryDiskError.unsupportedVersion }
            guard data.count <= HistoryFiles.maximumMetadataBytes else { throw HistoryDiskError.invalidArchive }
            let manifest = try decoder.decode(HistoryManifest.self, from: data)
            guard (1...256).contains(manifest.capacity), manifest.entries.count <= manifest.capacity,
                  Set(manifest.entries.map(\.id)).count == manifest.entries.count,
                  Set(manifest.entries.map(\.payload)).count == manifest.entries.count,
                  manifest.entries.allSatisfy({ (0...(16 * 1_024 * 1_024)).contains($0.byteCount) && (1...HistoryFiles.maximumPayloadBytes).contains($0.encodedBytes) && $0.checksum.count == 32 }),
                  manifest.entries.reduce(0, { $0 + $1.byteCount }) <= historyByteLimit else { throw HistoryDiskError.invalidArchive }
            var entries: [ClipboardEntry] = []
            var loadedPayloads: [UUID: StoredPayload] = [:]
            for record in manifest.entries {
                let payloadData = try files.read(Self.payloadName(record.payload), maximumBytes: record.encodedBytes)
                guard payloadData.count == record.encodedBytes,
                      Data(SHA256.hash(data: payloadData)) == record.checksum else { throw HistoryDiskError.invalidArchive }
                let payload = try decoder.decode(HistoryPayload.self, from: payloadData)
                guard payload.version == 1 else { throw HistoryDiskError.invalidArchive }
                let entry = ClipboardEntry(id: record.id, createdAt: record.createdAt, sourceApp: record.sourceApp, items: payload.items, isPinned: record.isPinned)
                guard entry.byteCount == record.byteCount else { throw HistoryDiskError.invalidArchive }
                entries.append(entry)
                loadedPayloads[entry.id] = StoredPayload(identifier: record.payload, items: payload.items, encodedBytes: record.encodedBytes, checksum: record.checksum)
            }
            try Self.validate(entries, capacity: manifest.capacity, historyByteLimit: historyByteLimit)
            // Corrupt/missing data above never causes deletion of potential recovery data.
            try files.removeUnusedPayloads(keeping: Set(manifest.entries.map(\.payload)))
            storedPayloads = loadedPayloads
            return LoadedHistory(entries: entries, capacity: manifest.capacity, needsMigration: false)
        }
    }

    private static func validate(_ entries: [ClipboardEntry], capacity: Int, historyByteLimit: Int) throws {
        guard (1...256).contains(capacity), entries.count <= capacity,
              Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ !$0.items.isEmpty && $0.byteCount <= 16 * 1_024 * 1_024 && $0.items.allSatisfy({ !$0.representations.isEmpty }) }),
              entries.reduce(0, { $0 + $1.byteCount }) <= historyByteLimit else { throw HistoryDiskError.invalidArchive }
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
                result = WriteResult(generation: snapshot.generation, errorMessage: "History could not finish saving or cleaning up: \(error.localizedDescription) Your current history remains available in memory.")
            }
            lock.lock()
            lastResult = result
            lock.unlock()
            completion(result)
        }
    }

    private func persist(_ entries: [ClipboardEntry], capacity: Int) throws {
        guard let files = try HistoryFiles(directory: directory, fileManager: fileManager, create: true) else { throw HistoryDiskError.invalidArchive }
        try files.removeTemporaryFiles()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        var records: [HistoryRecord] = []
        var nextPayloads: [UUID: StoredPayload] = [:]
        for entry in entries {
            let payload: StoredPayload
            if let saved = storedPayloads[entry.id], Self.sameItems(saved.items, entry.items),
               let attributes = try files.attributes(Self.payloadName(saved.identifier)),
               HistoryFiles.isOwnedRegularFile(attributes), attributes.st_size == saved.encodedBytes {
                payload = saved
            } else {
                let data = try encoder.encode(HistoryPayload(version: 1, items: entry.items))
                guard data.count <= HistoryFiles.maximumPayloadBytes else { throw HistoryDiskError.invalidArchive }
                payload = StoredPayload(identifier: UUID(), items: entry.items, encodedBytes: data.count, checksum: Data(SHA256.hash(data: data)))
                try files.writeAtomically(data, to: Self.payloadName(payload.identifier), temporaryPrefix: ".payload-")
            }
            nextPayloads[entry.id] = payload
            records.append(HistoryRecord(id: entry.id, createdAt: entry.createdAt, sourceApp: entry.sourceApp, isPinned: entry.isPinned, payload: payload.identifier, byteCount: entry.byteCount, encodedBytes: payload.encodedBytes, checksum: payload.checksum))
        }
        let manifest = try encoder.encode(HistoryManifest(version: 3, capacity: capacity, entries: records))
        guard manifest.count <= HistoryFiles.maximumMetadataBytes else { throw HistoryDiskError.invalidArchive }
        // Make payload renames durable before publishing their references.
        try files.synchronizeDirectory()
        try files.writeAtomically(manifest, to: "history.plist", temporaryPrefix: ".history-")
        try files.synchronizeDirectory()
        storedPayloads = nextPayloads
        // Only the successfully committed manifest determines what may be removed.
        try files.removeUnusedPayloads(keeping: Set(records.map(\.payload)))
    }

    private static func payloadName(_ identifier: UUID) -> String { "payload-\(identifier.uuidString).plist" }

    private static func sameItems(_ lhs: [ClipboardItem], _ rhs: [ClipboardItem]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) {
            guard left.representations.count == right.representations.count else { return false }
            for (a, b) in zip(left.representations, right.representations) {
                guard a.type == b.type, a.data.count == b.data.count else { return false }
                // Pin/order changes share Data backing; avoid rescanning all payload bytes.
                let identical = a.data.withUnsafeBytes { first in
                    b.data.withUnsafeBytes { second in first.baseAddress == second.baseAddress || first.elementsEqual(second) }
                }
                if !identical { return false }
            }
        }
        return true
    }
}

/// Descriptor-relative access prevents a final-path symlink or directory swap
/// from redirecting payload reads, writes, or cleanup outside the history folder.
private final class HistoryFiles {
    static let maximumMetadataBytes = 4 * 1_024 * 1_024
    static let maximumPayloadBytes = 20 * 1_024 * 1_024
    private let descriptor: Int32
    private let directory: URL
    private let fileManager: FileManager

    init?(directory: URL, fileManager: FileManager, create: Bool) throws {
        if create { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT && !create { return nil }
            throw Self.posixError()
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else { let error = Self.posixError(); close(fd); throw error }
        guard info.st_uid == getuid() else { close(fd); throw POSIXError(.EPERM) }
        guard fchmod(fd, 0o700) == 0 else { let error = Self.posixError(); close(fd); throw error }
        descriptor = fd
        self.directory = directory
        self.fileManager = fileManager
    }

    deinit { close(descriptor) }

    func attributes(_ name: String) throws -> stat? {
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return info }
        if errno == ENOENT { return nil }
        throw Self.posixError()
    }

    static func isOwnedRegularFile(_ info: stat) -> Bool {
        info.st_uid == getuid() && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    func read(_ name: String, maximumBytes: Int) throws -> Data {
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Self.posixError() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Self.posixError() }
        guard Self.isOwnedRegularFile(info), info.st_size >= 0, info.st_size <= maximumBytes else { throw HistoryDiskError.invalidArchive }
        guard fchmod(fd, 0o600) == 0 else { throw Self.posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        while let chunk = try handle.read(upToCount: min(1_024 * 1_024, maximumBytes - data.count + 1)), !chunk.isEmpty {
            guard data.count + chunk.count <= maximumBytes else { throw HistoryDiskError.invalidArchive }
            data.append(chunk)
        }
        return data
    }

    func writeAtomically(_ data: Data, to name: String, temporaryPrefix: String) throws {
        if let existing = try attributes(name), !Self.isOwnedRegularFile(existing) { throw POSIXError(.EPERM) }
        let temporary = "\(temporaryPrefix)\(UUID().uuidString).tmp"
        let fd = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Self.posixError() }
        defer { close(fd); unlinkat(descriptor, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Self.posixError() }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Self.posixError() }
        guard renameat(descriptor, temporary, descriptor, name) == 0 else { throw Self.posixError() }
    }

    func synchronizeDirectory() throws {
        guard fsync(descriptor) == 0 else { throw Self.posixError() }
    }

    func removeTemporaryFiles() throws {
        try removeMatching { name in
            Self.identifier(name, prefix: ".history-", suffix: ".tmp") != nil || Self.identifier(name, prefix: ".payload-", suffix: ".tmp") != nil
        }
    }

    func removeUnusedPayloads(keeping identifiers: Set<UUID>) throws {
        try removeMatching { name in
            guard let id = Self.identifier(name, prefix: "payload-", suffix: ".plist") else { return false }
            return !identifiers.contains(id)
        }
    }

    private func removeMatching(_ matches: (String) -> Bool) throws {
        var removed = false
        for name in try fileManager.contentsOfDirectory(atPath: directory.path) where matches(name) {
            guard let info = try attributes(name), Self.isOwnedRegularFile(info) else { continue }
            guard unlinkat(descriptor, name, 0) == 0 || errno == ENOENT else { throw Self.posixError() }
            removed = true
        }
        if removed { try synchronizeDirectory() }
    }

    private static func identifier(_ name: String, prefix: String, suffix: String) -> UUID? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let value = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard let identifier = UUID(uuidString: value), identifier.uuidString == value else { return nil }
        return identifier
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
