import Foundation
import XCTest
@testable import ClipCore

final class HistoryTemporaryFileTests: XCTestCase {
    func testStartupRemovesOnlyOwnedRegularHistoryTemporaryFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let orphan = directory.appendingPathComponent(".history-\(UUID().uuidString).tmp")
        let unknown = directory.appendingPathComponent(".history-not-a-uuid.tmp")
        let other = directory.appendingPathComponent("unrelated.tmp")
        let nestedDirectory = directory.appendingPathComponent(".history-\(UUID().uuidString).tmp")
        let link = directory.appendingPathComponent(".history-\(UUID().uuidString).tmp")
        let history = directory.appendingPathComponent("history.plist")
        let bytes = Data("synthetic clipboard fixture".utf8)
        try bytes.write(to: orphan)
        try bytes.write(to: unknown)
        try bytes.write(to: other)
        try bytes.write(to: history) // Deliberately corrupt canonical archive stays untouched.
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: false)
        try bytes.write(to: nestedDirectory.appendingPathComponent("keep.txt"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)

        await MainActor.run {
            let store = HistoryStore(directory: directory)
            XCTAssertNotNil(store.errorMessage)
            store.flush()
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(try Data(contentsOf: history), bytes)
        XCTAssertEqual(try Data(contentsOf: unknown), bytes)
        XCTAssertEqual(try Data(contentsOf: other), bytes)
        XCTAssertEqual(try Data(contentsOf: nestedDirectory.appendingPathComponent("keep.txt")), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), other.path)
    }

    func testClearRemovesAnOrphanLeftAfterStartup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await MainActor.run {
            let store = HistoryStore(directory: directory)
            store.insert(ClipboardEntry(items: [ClipboardItem(representations: [
                ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("synthetic old text".utf8))
            ])]))
            store.flush()
            let orphan = directory.appendingPathComponent(".history-\(UUID().uuidString).tmp")
            // Emulate a process exit between writing a snapshot and renaming it.
            try FileManager.default.copyItem(at: store.historyURL, to: orphan)
            store.clear()
            store.flush()
            XCTAssertNil(store.errorMessage)
            XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
            let reloaded = HistoryStore(directory: directory)
            XCTAssertTrue(reloaded.entries.isEmpty)
            reloaded.flush()
        }
    }

    func testCleanupDoesNotFollowASymbolicLinkDirectory() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = parent.appendingPathComponent("real", isDirectory: true)
        let link = parent.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let orphan = directory.appendingPathComponent(".history-\(UUID().uuidString).tmp")
        let bytes = Data("synthetic fixture outside linked directory".utf8)
        try bytes.write(to: orphan)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)

        await MainActor.run {
            let store = HistoryStore(directory: link)
            XCTAssertNotNil(store.errorMessage)
            store.flush()
        }
        XCTAssertEqual(try Data(contentsOf: orphan), bytes)
    }
}
