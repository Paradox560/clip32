import Darwin
import Foundation
import XCTest
@testable import ClipCore

final class HistoryPayloadStorageTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Clip32PayloadTests-\(UUID().uuidString)")
    }

    private func entry(_ text: String, id: UUID = UUID()) -> ClipboardEntry {
        ClipboardEntry(id: id, items: [ClipboardItem(representations: [ClipboardRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))])])
    }

    private func payloadFiles(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("payload-") && $0.pathExtension == "plist" }
    }

    private func manifest(_ directory: URL) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: directory.appendingPathComponent("history.plist")), format: nil) as? [String: Any])
    }

    func testVersionTwoAutomaticallyMigratesWithoutLosingContentOrPins() async throws {
        struct Archive: Encodable { let version = 2; let capacity = 64; let entries: [ClipboardEntry] }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var pin = entry("Synthetic pinned legacy text")
        pin.isPinned = true
        let expected = [entry("Recent legacy text"), pin]
        try PropertyListEncoder().encode(Archive(entries: expected)).write(to: directory.appendingPathComponent("history.plist"))
        try await MainActor.run {
            let store = HistoryStore(directory: directory)
            XCTAssertEqual(store.entries, expected)
            store.flush()
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(try manifest(directory)["version"] as? Int, 3)
            XCTAssertEqual(try payloadFiles(directory).count, 2)
            let reloaded = HistoryStore(directory: directory)
            XCTAssertEqual(reloaded.capacity, 64)
            XCTAssertEqual(reloaded.entries, expected)
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
                XCTAssertTrue(file.lastPathComponent == "history.plist" || file.lastPathComponent.hasPrefix("payload-"), "No full legacy archive backup should survive migration.")
            }
        }
    }

    func testPinRecopyAndCapacityChangesReusePayloadFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await MainActor.run {
            let store = HistoryStore(directory: directory)
            let first = entry(String(repeating: "A", count: 512 * 1_024))
            let second = entry(String(repeating: "B", count: 512 * 1_024))
            store.insert(first)
            store.insert(second)
            store.flush()
            let files = try payloadFiles(directory)
            let dataBefore = try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
            let attributesBefore = try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try FileManager.default.attributesOfItem(atPath: $0.path)) })
            for _ in 0..<10 { store.togglePin(id: first.id); store.flush() }
            var recopy = first
            recopy.createdAt = Date(timeIntervalSince1970: 1_000)
            recopy.sourceApp = "Synthetic source"
            store.insert(recopy)
            store.setCapacity(64)
            store.flush()
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(Set(try payloadFiles(directory).map(\.lastPathComponent)), Set(files.map(\.lastPathComponent)))
            for file in files {
                let after = try FileManager.default.attributesOfItem(atPath: file.path)
                XCTAssertEqual(after[.systemFileNumber] as? NSNumber, attributesBefore[file.lastPathComponent]?[.systemFileNumber] as? NSNumber)
                XCTAssertEqual(after[.modificationDate] as? Date, attributesBefore[file.lastPathComponent]?[.modificationDate] as? Date)
                XCTAssertEqual(try Data(contentsOf: file), dataBefore[file.lastPathComponent])
            }
            XCTAssertLessThan(try Data(contentsOf: store.historyURL).count, 8 * 1_024)
            XCTAssertEqual(HistoryStore(directory: directory).entries, store.entries)
            XCTAssertEqual(HistoryStore(directory: directory).capacity, 64)
        }
    }

    func testFailedManifestLeavesPreviousHistoryLoadableAndNewPayloadRecoverable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await MainActor.run {
            let store = HistoryStore(directory: directory)
            let original = entry("Committed fixture")
            store.insert(original)
            store.flush()
            let committed = try Data(contentsOf: store.historyURL)
            let oldPayloads = Set(try payloadFiles(directory).map(\.lastPathComponent))
            var uncommitted = entry("Payload written before oversized metadata fails")
            uncommitted.sourceApp = String(repeating: "S", count: 5 * 1_024 * 1_024)
            store.insert(uncommitted)
            store.flush()
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(try Data(contentsOf: store.historyURL), committed)
            XCTAssertGreaterThan(try payloadFiles(directory).count, oldPayloads.count)
            let reloaded = HistoryStore(directory: directory)
            XCTAssertNil(reloaded.errorMessage)
            XCTAssertEqual(reloaded.entries, [original])
            XCTAssertEqual(Set(try payloadFiles(directory).map(\.lastPathComponent)), oldPayloads)
        }
    }

    func testChecksumFailurePreservesRecoveryDataUntilExplicitClear() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await MainActor.run {
            let initial = HistoryStore(directory: directory)
            initial.insert(entry("Original payload"))
            initial.flush()
            let payload = try XCTUnwrap(payloadFiles(directory).first)
            var damaged = try Data(contentsOf: payload)
            damaged[damaged.startIndex] ^= 1
            try damaged.write(to: payload)
            let orphan = directory.appendingPathComponent("payload-\(UUID().uuidString).plist")
            try Data("Potential recovery fixture".utf8).write(to: orphan)
            let manifestBefore = try Data(contentsOf: initial.historyURL)
            let reloaded = HistoryStore(directory: directory)
            XCTAssertNotNil(reloaded.errorMessage)
            reloaded.insert(entry("Session only"))
            reloaded.flush()
            XCTAssertEqual(try Data(contentsOf: initial.historyURL), manifestBefore)
            XCTAssertEqual(try Data(contentsOf: payload), damaged)
            XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
            reloaded.clear()
            reloaded.flush()
            XCTAssertNil(reloaded.errorMessage)
            XCTAssertTrue(try payloadFiles(directory).isEmpty)
            XCTAssertTrue(HistoryStore(directory: directory).entries.isEmpty)
        }
    }

    func testMissingPayloadDoesNotSilentlyDropEntriesOrReplaceManifest() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await MainActor.run {
            let initial = HistoryStore(directory: directory)
            initial.insert(entry("Missing fixture"))
            initial.flush()
            let payload = try XCTUnwrap(payloadFiles(directory).first)
            try FileManager.default.removeItem(at: payload)
            let original = try Data(contentsOf: initial.historyURL)
            let store = HistoryStore(directory: directory)
            XCTAssertNotNil(store.errorMessage)
            store.insert(entry("Session only"))
            store.flush()
            XCTAssertEqual(try Data(contentsOf: initial.historyURL), original)
        }
    }

    func testGarbageCollectionPreservesUnrelatedFilesDirectoriesAndSymlinks() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await MainActor.run {
            let initial = HistoryStore(directory: directory)
            initial.insert(entry("Committed fixture"))
            initial.flush()
            let originalPayloads = Set(try payloadFiles(directory).map(\.lastPathComponent))
            let orphan = directory.appendingPathComponent("payload-\(UUID().uuidString).plist")
            let unrelated = directory.appendingPathComponent("payload-not-a-uuid.plist")
            let nested = directory.appendingPathComponent("payload-\(UUID().uuidString).plist")
            let link = directory.appendingPathComponent("payload-\(UUID().uuidString).plist")
            let temporary = directory.appendingPathComponent(".payload-\(UUID().uuidString).tmp")
            for file in [orphan, unrelated, temporary] { try Data("Synthetic fixture".utf8).write(to: file) }
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            try Data("Keep nested".utf8).write(to: nested.appendingPathComponent("keep.txt"))
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
            let reloaded = HistoryStore(directory: directory)
            XCTAssertNil(reloaded.errorMessage)
            XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent("keep.txt").path))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), unrelated.path)
            for name in originalPayloads { XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)) }
            reloaded.clear()
            reloaded.flush()
            for name in originalPayloads { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent("keep.txt").path))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), unrelated.path)
        }
    }

    func testSymlinkAndOversizedPayloadsAreRejectedBeforeDecoding() async throws {
        for symlink in [true, false] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try await MainActor.run {
                let initial = HistoryStore(directory: directory)
                initial.insert(entry("Bounded fixture"))
                initial.flush()
                let payload = try XCTUnwrap(payloadFiles(directory).first)
                let untouched = directory.appendingPathComponent("unrelated.txt")
                try Data("Do not read or remove through the symlink".utf8).write(to: untouched)
                if symlink {
                    try FileManager.default.removeItem(at: payload)
                    try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: untouched)
                } else {
                    let handle = try FileHandle(forWritingTo: payload)
                    try handle.truncate(atOffset: 21 * 1_024 * 1_024)
                    try handle.close()
                }
                let manifestBefore = try Data(contentsOf: initial.historyURL)
                let store = HistoryStore(directory: directory)
                XCTAssertNotNil(store.errorMessage)
                XCTAssertTrue(store.entries.isEmpty)
                XCTAssertEqual(try Data(contentsOf: initial.historyURL), manifestBefore)
                XCTAssertEqual(try String(contentsOf: untouched), "Do not read or remove through the symlink")
            }
        }
    }

    func testDuplicateIDsAndPathTraversalPayloadReferencesAreRejected() async throws {
        for duplicate in [true, false] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try await MainActor.run {
                let initial = HistoryStore(directory: directory)
                initial.insert(entry("First"))
                initial.insert(entry("Second"))
                initial.flush()
                var document = try manifest(directory)
                var records = try XCTUnwrap(document["entries"] as? [[String: Any]])
                if duplicate { records[1]["id"] = records[0]["id"] }
                else { records[0]["payload"] = "../../outside" }
                document["entries"] = records
                let invalid = try PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0)
                try invalid.write(to: initial.historyURL)
                let store = HistoryStore(directory: directory)
                XCTAssertNotNil(store.errorMessage)
                store.insert(entry("Session only"))
                store.flush()
                XCTAssertEqual(try Data(contentsOf: initial.historyURL), invalid)
                XCTAssertEqual(try payloadFiles(directory).count, 2)
            }
        }
    }

    func testDifferentContentWithReusedCallerIDCannotAliasPayloads() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await MainActor.run {
            let store = HistoryStore(directory: directory)
            let first = entry("First")
            store.insert(first)
            store.flush()
            store.insert(entry("Different bytes", id: first.id))
            store.flush()
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(Set(store.entries.map(\.id)).count, 2)
            let reloaded = HistoryStore(directory: directory)
            XCTAssertNil(reloaded.errorMessage)
            XCTAssertEqual(reloaded.entries, store.entries)
        }
    }

    func testNamedPipeArchiveIsRejectedWithoutWaitingForAWriter() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("history.plist")
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        await MainActor.run {
            let store = HistoryStore(directory: directory)
            XCTAssertNotNil(store.errorMessage)
            XCTAssertTrue(store.entries.isEmpty)
        }
    }
}
