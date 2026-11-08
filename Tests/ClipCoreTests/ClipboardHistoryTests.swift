import AppKit
import XCTest
@testable import ClipCore

final class ClipboardHistoryTests: XCTestCase {
    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Clip32Tests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func textEntry(_ text: String, date: Date = Date()) -> ClipboardEntry {
        ClipboardEntry(createdAt: date, items: [ClipboardItem(representations: [
            ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))
        ])])
    }

    func testKeepsMostRecent32EntriesAndReloadsThem() async throws {
        try await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            for number in 0..<40 { XCTAssertTrue(store.insert(Self.textEntry("Entry \(number)"))) }
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.entries.count, 32)
            XCTAssertEqual(store.entries.first?.title, "Entry 39")
            XCTAssertEqual(store.entries.last?.title, "Entry 8")
            store.flush()
            let reloaded = HistoryStore(directory: directory)
            XCTAssertEqual(reloaded.entries, store.entries)
            let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
            let filePermissions = try FileManager.default.attributesOfItem(atPath: store.historyURL.path)[.posixPermissions] as? Int
            XCTAssertEqual(directoryPermissions, 0o700)
            XCTAssertEqual(filePermissions, 0o600)
        }
    }

    func testDuplicateMovesToFrontAndKeepsPinWithUpdatedTime() async {
        await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            let original = Self.textEntry("Keep me", date: Date(timeIntervalSince1970: 1))
            store.insert(original)
            store.togglePin(id: original.id)
            store.insert(Self.textEntry("Other entry"))
            let recopy = Self.textEntry("Keep me", date: Date(timeIntervalSince1970: 10))
            store.insert(recopy)
            XCTAssertEqual(store.entries.count, 2)
            XCTAssertEqual(store.entries.first?.id, original.id)
            XCTAssertEqual(store.entries.first?.isPinned, true)
            XCTAssertEqual(store.entries.first?.createdAt, recopy.createdAt)
        }
    }

    func testPinnedOldestEntrySurvivesEvictionAndClearRecent() async {
        await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            let pinned = Self.textEntry("Pinned oldest")
            store.insert(pinned)
            store.togglePin(id: pinned.id)
            for number in 0..<40 { store.insert(Self.textEntry("Copy \(number)")) }
            XCTAssertEqual(store.entries.count, 32)
            XCTAssertEqual(store.entries.last?.id, pinned.id)
            XCTAssertFalse(store.entries.contains { $0.title == "Copy 8" })
            store.clearUnpinned()
            XCTAssertEqual(store.entries.map(\.id), [pinned.id])
            store.flush()
            let reloaded = HistoryStore(directory: directory)
            XCTAssertEqual(reloaded.entries.first?.isPinned, true)
            store.clear()
            store.flush()
            XCTAssertTrue(HistoryStore(directory: directory).entries.isEmpty)
        }
    }

    func testAllPinnedHistoryRejectsNewCopiesWithoutExceeding32() async {
        await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            for number in 0..<32 {
                var entry = Self.textEntry("Pinned \(number)")
                entry.isPinned = true
                store.insert(entry)
            }
            XCTAssertFalse(store.insert(Self.textEntry("Cannot fit")))
            XCTAssertEqual(store.entries.count, 32)
            XCTAssertNotNil(store.errorMessage)
            XCTAssertTrue(store.insert(Self.textEntry("Pinned 0")))
            XCTAssertEqual(store.entries.first?.title, "Pinned 0")
            XCTAssertEqual(store.entries.first?.isPinned, true)
            store.togglePin(id: store.entries.last!.id)
            XCTAssertTrue(store.insert(Self.textEntry("Can fit now")))
            XCTAssertEqual(store.entries.count, 32)
        }
    }

    func testCorruptSavedHistoryIsPreservedUntilExplicitClear() async throws {
        try await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("history.plist")
            let originalBytes = Data("not a valid archive".utf8)
            try originalBytes.write(to: file)
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            XCTAssertNotNil(store.errorMessage)
            store.insert(Self.textEntry("Session only"))
            XCTAssertEqual(try Data(contentsOf: file), originalBytes)
            XCTAssertEqual(store.entries.count, 1)
            store.clear()
            store.flush()
            XCTAssertNil(store.errorMessage)
            XCTAssertTrue(HistoryStore(directory: directory).entries.isEmpty)
        }
    }

    func testMonitorCapturesNewCopiesButNotExistingOrPausedClipboard() async {
        await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.setString("Predates app", forType: .string)
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
            monitor.captureNow()
            XCTAssertTrue(store.entries.isEmpty)
            pasteboard.clearContents()
            pasteboard.setString("New copy", forType: .string)
            monitor.captureNow()
            monitor.captureNow()
            XCTAssertEqual(store.entries.map(\.title), ["New copy"])
            monitor.isPaused = true
            pasteboard.clearContents()
            pasteboard.setString("Private paused copy", forType: .string)
            monitor.isPaused = false
            monitor.captureNow()
            XCTAssertEqual(store.entries.count, 1)
        }
    }

    func testConfidentialMarkerPreventsCapturingAnyItem() async {
        await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
            let privateItem = NSPasteboardItem()
            privateItem.setString("Secret", forType: .string)
            privateItem.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            pasteboard.clearContents()
            pasteboard.writeObjects([privateItem])
            monitor.captureNow()
            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertNotNil(monitor.notice)
        }
    }

    func testMultipleFileURLsRoundTripWithoutReadingFilesAndOwnWriteIsIgnored() async {
        await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
            let urls = [URL(fileURLWithPath: "/tmp/Clip32 test nonexistent one.txt"), URL(fileURLWithPath: "/tmp/Clip32-test-nonexistent-two.png")]
            let objects = urls.map { url -> NSPasteboardItem in
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                return item
            }
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects(objects))
            monitor.captureNow()
            XCTAssertEqual(store.entries.count, 1)
            guard let entry = store.entries.first else { return XCTFail("The synthetic clipboard entry was not captured.") }
            XCTAssertEqual(entry.kind, .files)
            XCTAssertEqual(entry.fileURLs, urls)
            store.flush()
            XCTAssertEqual(HistoryStore(directory: directory).entries.first?.fileURLs, urls)
            XCTAssertTrue(monitor.restore(entry))
            XCTAssertEqual(pasteboard.pasteboardItems?.compactMap { $0.string(forType: .fileURL) }, urls.map(\.absoluteString))
            monitor.captureNow()
            XCTAssertEqual(store.entries.count, 1)
        }
    }

    func testRichTextAndImageRepresentationsRoundTrip() async {
        await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
            let item = NSPasteboardItem()
            let imageBytes = Data([137, 80, 78, 71, 13, 10, 26, 10])
            item.setData(imageBytes, forType: .png)
            item.setString("<b>Caption</b>", forType: .html)
            item.setString("Caption", forType: .string)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            monitor.captureNow()
            guard let entry = store.entries.first else { return XCTFail("The synthetic clipboard entry was not captured.") }
            XCTAssertEqual(entry.kind, .image)
            XCTAssertEqual(entry.imageData, imageBytes)
            XCTAssertTrue(monitor.restore(entry))
            XCTAssertEqual(pasteboard.data(forType: .png), imageBytes)
            XCTAssertEqual(pasteboard.string(forType: .html), "<b>Caption</b>")
            XCTAssertEqual(pasteboard.string(forType: .string), "Caption")
        }
    }

    func testRepresentationOrderDoesNotCreateDuplicateHistory() async {
        await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            let plain = ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("Hello".utf8))
            let rich = ClipboardRepresentation(type: NSPasteboard.PasteboardType.html.rawValue, data: Data("<b>Hello</b>".utf8))
            store.insert(ClipboardEntry(items: [ClipboardItem(representations: [plain, rich])]))
            store.insert(ClipboardEntry(items: [ClipboardItem(representations: [rich, plain])]))
            XCTAssertEqual(store.entries.count, 1)
        }
    }

    func testOversizedEntriesAreRejectedWithoutReplacingHistory() async {
        await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            store.insert(Self.textEntry("Keep"))
            let huge = ClipboardEntry(items: [ClipboardItem(representations: [
                ClipboardRepresentation(type: NSPasteboard.PasteboardType.png.rawValue, data: Data(repeating: 0, count: HistoryStore.maximumEntryBytes + 1))
            ])])
            XCTAssertFalse(store.insert(huge))
            store.flush()
            XCTAssertEqual(store.entries.map(\.title), ["Keep"])
            XCTAssertTrue(store.errorMessage?.contains("16 MB") == true, "An earlier successful write must not erase this later validation error.")
        }
    }

    func testQueuedWritesDoNotResurrectClearedOrRemovedEntries() async {
        await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            for number in 0..<200 { store.insert(Self.textEntry("Queued \(number)")) }
            store.clear()
            store.flush()
            XCTAssertTrue(HistoryStore(directory: directory).entries.isEmpty)
            let last = Self.textEntry("Remove before disk catches up")
            store.insert(last)
            store.remove(id: last.id)
            store.flush()
            XCTAssertTrue(HistoryStore(directory: directory).entries.isEmpty)
            store.insert(Self.textEntry("Final snapshot"))
            store.flush()
            XCTAssertEqual(HistoryStore(directory: directory).entries.map(\.title), ["Final snapshot"])
        }
    }

    func testWriteFailureIsVisibleAndLaterWriteCanRecover() async throws {
        try await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try Data("A file obstructs this directory".utf8).write(to: directory)
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            store.insert(Self.textEntry("Still in memory"))
            store.flush()
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(store.entries.count, 1)
            try FileManager.default.removeItem(at: directory)
            store.insert(Self.textEntry("Recovered"))
            store.flush()
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(HistoryStore(directory: directory).entries.map(\.title), ["Recovered", "Still in memory"])
        }
    }

    func testOversizedArchiveIsRejectedBeforeReadingItsContents() async throws {
        try await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let archive = directory.appendingPathComponent("history.plist")
            XCTAssertTrue(FileManager.default.createFile(atPath: archive.path, contents: Data()))
            let handle = try FileHandle(forWritingTo: archive)
            let oversizedLength = UInt64(HistoryStore.maximumHistoryBytes + 5 * 1_024 * 1_024)
            try handle.truncate(atOffset: oversizedLength)
            try handle.close()
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertNotNil(store.errorMessage)
            store.insert(Self.textEntry("Session only"))
            store.flush()
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.uint64Value, oversizedLength)
        }
    }

    func testCapacityBoundsAreValidatedAndSavedWithoutEntries() async {
        await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            XCTAssertEqual(store.capacity, 32)
            XCTAssertFalse(store.setCapacity(0))
            XCTAssertFalse(store.setCapacity(257))
            XCTAssertEqual(store.capacity, 32)
            XCTAssertTrue(store.setCapacity(1))
            store.flush()
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(HistoryStore(directory: directory).capacity, 1)
            XCTAssertTrue(store.setCapacity(256))
            store.flush()
            XCTAssertEqual(HistoryStore(directory: directory).capacity, 256)
        }
    }

    func testExpandedCapacityKeeps256EntriesAndPersistsNewestHistory() async {
        await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            XCTAssertTrue(store.setCapacity(256))
            for number in 0..<300 { XCTAssertTrue(store.insert(Self.textEntry("Expanded \(number)"))) }
            XCTAssertEqual(store.entries.count, 256)
            XCTAssertEqual(store.entries.first?.title, "Expanded 299")
            XCTAssertEqual(store.entries.last?.title, "Expanded 44")
            store.flush()
            let reloaded = HistoryStore(directory: directory)
            XCTAssertEqual(reloaded.capacity, 256)
            XCTAssertEqual(reloaded.entries, store.entries)
        }
    }

    func testReducingCapacityRetainsPinsAndNewestUnpinnedItems() async {
        await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            var pin = Self.textEntry("Old pin")
            pin.isPinned = true
            store.insert(pin)
            for number in 0..<6 { store.insert(Self.textEntry("Recent \(number)")) }
            XCTAssertTrue(store.setCapacity(3))
            XCTAssertEqual(store.entries.map(\.title), ["Recent 5", "Recent 4", "Old pin"])
            XCTAssertEqual(store.entries.last?.id, pin.id)
            store.flush()
            let reloaded = HistoryStore(directory: directory)
            XCTAssertEqual(reloaded.capacity, 3)
            XCTAssertEqual(reloaded.entries, store.entries)
            XCTAssertTrue(store.setCapacity(1))
            XCTAssertEqual(store.entries.map(\.title), ["Old pin"])
            XCTAssertFalse(store.insert(Self.textEntry("Pinned capacity is full")))
            XCTAssertEqual(store.entries.map(\.title), ["Old pin"])
        }
    }

    func testReducingBelowPinnedCountRejectsChangeWithoutLosingEntries() async {
        await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            for number in 0..<3 {
                var pin = Self.textEntry("Pin \(number)")
                pin.isPinned = true
                store.insert(pin)
            }
            store.insert(Self.textEntry("Recent"))
            let previousEntries = store.entries
            XCTAssertFalse(store.setCapacity(2))
            store.flush()
            XCTAssertEqual(store.capacity, 32)
            XCTAssertEqual(store.entries, previousEntries)
            XCTAssertTrue(store.errorMessage?.contains("3 pinned items") == true)
            XCTAssertEqual(HistoryStore(directory: directory).capacity, 32)
            XCTAssertTrue(store.setCapacity(3))
            XCTAssertEqual(store.entries.count, 3)
            XCTAssertTrue(store.entries.allSatisfy(\.isPinned))
        }
    }

    func testLegacyArchiveLoadsAt32AndMigratesCapacityWithoutLosingEntries() async throws {
        struct LegacyArchive: Encodable {
            let version = 1
            let entries: [ClipboardEntry]
        }
        try await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var pin = Self.textEntry("Legacy pinned entry")
            pin.isPinned = true
            let entries = [Self.textEntry("Legacy recent entry"), pin]
            let archiveURL = directory.appendingPathComponent("history.plist")
            try PropertyListEncoder().encode(LegacyArchive(entries: entries)).write(to: archiveURL)
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.capacity, 32)
            XCTAssertEqual(store.entries, entries)
            XCTAssertTrue(store.setCapacity(64))
            store.flush()
            let archive = try PropertyListSerialization.propertyList(from: Data(contentsOf: archiveURL), format: nil) as? [String: Any]
            XCTAssertEqual(archive?["version"] as? Int, 3)
            XCTAssertEqual(archive?["capacity"] as? Int, 64)
            let reloaded = HistoryStore(directory: directory)
            XCTAssertEqual(reloaded.capacity, 64)
            XCTAssertEqual(reloaded.entries, entries)
        }
    }

    func testInvalidSavedCapacityIsPreservedInsteadOfClampedOrOverwritten() async throws {
        struct InvalidArchive: Encodable {
            let version = 2
            let capacity = 257
            let entries: [ClipboardEntry] = []
        }
        try await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let archiveURL = directory.appendingPathComponent("history.plist")
            let originalData = try PropertyListEncoder().encode(InvalidArchive())
            try originalData.write(to: archiveURL)
            let store = HistoryStore(directory: directory)
            defer { store.flush() }
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(store.capacity, 32)
            store.insert(Self.textEntry("Session only"))
            store.flush()
            XCTAssertEqual(try Data(contentsOf: archiveURL), originalData)
        }
    }

    func testStorageBudgetEvictsOldestUnpinnedItemsEvenBelowCountLimit() async {
        await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = HistoryStore(directory: directory, fileManager: .default, historyByteLimit: 12)
            defer { store.flush() }
            var pin = Self.textEntry("keep")
            pin.isPinned = true
            XCTAssertTrue(store.insert(pin))
            XCTAssertTrue(store.insert(Self.textEntry("aaaa")))
            XCTAssertTrue(store.insert(Self.textEntry("bbbb")))
            XCTAssertEqual(store.totalBytes, 12)
            XCTAssertTrue(store.insert(Self.textEntry("cccccc")))
            XCTAssertEqual(store.entries.map(\.title), ["cccccc", "keep"])
            XCTAssertEqual(store.totalBytes, 10)
            store.flush()
            let reloaded = HistoryStore(directory: directory, fileManager: .default, historyByteLimit: 12)
            XCTAssertEqual(reloaded.entries, store.entries)
            XCTAssertEqual(reloaded.capacity, 32)
        }
    }

    func testStorageBudgetNeverDropsPinsOrMutatesHistoryAfterFailedInsert() async {
        await MainActor.run {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = HistoryStore(directory: directory, fileManager: .default, historyByteLimit: 12)
            defer { store.flush() }
            for text in ["keep", "pins"] {
                var pin = Self.textEntry(text)
                pin.isPinned = true
                store.insert(pin)
            }
            store.insert(Self.textEntry("old"))
            let previousEntries = store.entries
            XCTAssertFalse(store.insert(Self.textEntry("12345")))
            store.flush()
            XCTAssertEqual(store.entries, previousEntries, "Tentative eviction must not affect history if the new entry still cannot fit.")
            XCTAssertNotNil(store.errorMessage)
            XCTAssertTrue(store.insert(Self.textEntry("keep")))
            XCTAssertEqual(store.entries.first?.isPinned, true)
            XCTAssertEqual(store.totalBytes, 11)
        }
    }
}
