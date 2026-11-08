// Synthetic archive-write benchmark. Never reads the system clipboard/history.
// swiftc -O -module-cache-path .build/module-cache \
//   Sources/ClipCore/ClipboardEntry.swift Sources/ClipCore/HistoryStore.swift \
//   Sources/ClipCore/HistoryPersistence.swift Scripts/Benchmarks/HistoryStorageBenchmark.swift \
//   -framework AppKit -o /tmp/clip32-history-benchmark
// /tmp/clip32-history-benchmark
import Foundation

@main @MainActor
struct HistoryPersistenceBenchmark {
    struct FileState: Equatable {
        let inode: UInt64
        let modified: Date
        let bytes: Int
    }

    static func files(in directory: URL) throws -> [String: FileState] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        return try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "plist" }
            .map { file in
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                return (file.lastPathComponent, FileState(inode: (attributes[.systemFileNumber] as! NSNumber).uint64Value,
                    modified: attributes[.modificationDate] as! Date, bytes: (attributes[.size] as! NSNumber).intValue))
            })
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clip32StorageBenchmark-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        var previous: [String: FileState] = [:]
        var insertionBytes = 0
        for number in 1...16 {
            let entry = ClipboardEntry(items: [ClipboardItem(representations: [
                ClipboardRepresentation(type: "public.utf8-plain-text", data: Data(repeating: UInt8(number), count: 1_024 * 1_024))
            ])])
            store.insert(entry)
            store.flush()
            guard store.errorMessage == nil else { fatalError(store.errorMessage!) }
            let current = try files(in: directory)
            insertionBytes += current.reduce(0) { $0 + (previous[$1.key] == $1.value ? 0 : $1.value.bytes) }
            previous = current
        }
        print("entries=16 payload_bytes=\(store.totalBytes) insertion_logical_bytes=\(insertionBytes)")
        for operation in ["pin", "recopy"] {
            let payloadBefore = previous.filter { $0.key.hasPrefix("payload-") }
            var logicalBytes = 0
            var duration = 0.0
            for iteration in 0..<10 {
                let start = CFAbsoluteTimeGetCurrent()
                if operation == "pin" {
                    store.togglePin(id: store.entries[0].id)
                } else {
                    var entry = store.entries.last!
                    entry.createdAt = Date(timeIntervalSince1970: Double(iteration))
                    store.insert(entry)
                }
                store.flush()
                duration += (CFAbsoluteTimeGetCurrent() - start) * 1_000
                guard store.errorMessage == nil else { fatalError(store.errorMessage!) }
                let current = try files(in: directory)
                logicalBytes += current.reduce(0) { $0 + (previous[$1.key] == $1.value ? 0 : $1.value.bytes) }
                previous = current
            }
            let payloadAfter = previous.filter { $0.key.hasPrefix("payload-") }
            print("operation=\(operation) count=10 logical_bytes=\(logicalBytes) mean_ms=\(duration / 10) payload_files_unchanged=\(payloadBefore == payloadAfter) manifest_bytes=\(previous["history.plist"]!.bytes)")
        }
        let reloaded = HistoryStore(directory: directory)
        reloaded.flush()
        guard reloaded.entries == store.entries else { fatalError("Reload mismatch") }
        print("reload_matches=true")
    }
}
