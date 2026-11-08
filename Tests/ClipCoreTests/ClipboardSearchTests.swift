import AppKit
import XCTest
@testable import ClipCore

final class ClipboardSearchTests: XCTestCase {
    private func text(_ text: String, id: UUID = UUID()) -> ClipboardEntry {
        ClipboardEntry(id: id, items: [ClipboardItem(representations: [
            ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))
        ])])
    }

    func testRepeatedQueriesReuseTextAndPreserveUpdatedMetadataAndOrdering() throws {
        var extractions = 0
        let index = ClipboardSearchIndex { entry in extractions += 1; return entry.searchableText }
        var first = text("First matching clip")
        let second = text("Second matching clip")
        XCTAssertEqual(try XCTUnwrap(index.search([first, second], query: "FIRST", filter: .all)).map(\.id), [first.id])
        XCTAssertEqual(try XCTUnwrap(index.search([first, second], query: "second", filter: .all)).map(\.id), [second.id])
        first.isPinned = true
        first.sourceApp = "Changed source"
        first.createdAt = .distantFuture
        XCTAssertEqual(index.search([second, first], query: "clip", filter: .all), [second, first])
        XCTAssertEqual(index.search([second, first], query: "clip", filter: .pinned), [first])
        XCTAssertEqual(extractions, 2)
    }

    func testPayloadMutationWithTheSameIdentifierInvalidatesText() {
        var extractions = 0
        let index = ClipboardSearchIndex { entry in extractions += 1; return entry.searchableText }
        let original = text("Original")
        let replacement = text("Replacement", id: original.id)
        XCTAssertEqual(index.search([original], query: "original", filter: .all), [original])
        XCTAssertEqual(index.search([replacement], query: "original", filter: .all), [])
        XCTAssertEqual(index.search([replacement], query: "replacement", filter: .all), [replacement])
        XCTAssertEqual(extractions, 2)
    }

    func testCacheBudgetUsesLRUEvictionAndRemovedEntriesAreReleased() {
        var extractions: [UUID: Int] = [:]
        let index = ClipboardSearchIndex(maximumCachedBytes: 60) { entry in
            extractions[entry.id, default: 0] += 1
            return entry.searchableText
        }
        let entries = [text("0123456789"), text("abcdefghij"), text("klmnopqrst")]
        _ = index.search(Array(entries.prefix(2)), query: "not found", filter: .all)
        XCTAssertEqual(index.cachedByteCount, 60)
        XCTAssertEqual(index.cachedEntryCount, 2)
        // Access the first entry while retaining both, then add the third. The
        // second is least recently used and must be extracted on the next scan.
        _ = index.search(entries, query: "not found", filter: .pinned)
        var pinned = entries[0]
        pinned.isPinned = true
        _ = index.search([pinned, entries[1]], query: "0", filter: .pinned)
        var thirdPinned = entries[2]
        thirdPinned.isPinned = true
        _ = index.search([pinned, entries[1], thirdPinned], query: "k", filter: .pinned)
        XCTAssertEqual(index.cachedByteCount, 60)
        XCTAssertEqual(index.cachedEntryCount, 2)
        _ = index.search(entries, query: "a", filter: .all)
        XCTAssertEqual(extractions[entries[1].id], 2)
        index.synchronize(with: [])
        XCTAssertEqual(index.cachedByteCount, 0)
        XCTAssertEqual(index.cachedEntryCount, 0)
    }

    func testOversizedTextStillMatchesAtTheEndWithoutBeingRetained() {
        let index = ClipboardSearchIndex(maximumCachedBytes: 30)
        let entry = text(String(repeating: "A", count: 100_000) + " needle-at-the-end")
        XCTAssertEqual(index.search([entry], query: "NEEDLE-AT-THE-END", filter: .all), [entry])
        XCTAssertEqual(index.cachedEntryCount, 0)
        XCTAssertEqual(index.cachedByteCount, 0)
    }

    func testRTFUnicodeAndFileSearchMatchTheExistingFullTextSemantics() throws {
        let string = "Café 👩🏽‍💻\n" + String(repeating: "plain text ", count: 3_000) + " Final needle"
        let attributed = NSAttributedString(string: string)
        let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let rich = ClipboardEntry(items: [ClipboardItem(representations: [.init(type: NSPasteboard.PasteboardType.rtf.rawValue, data: rtf)])])
        let file = ClipboardEntry(items: [ClipboardItem(representations: [.init(type: NSPasteboard.PasteboardType.fileURL.rawValue, data: Data("file:///tmp/Needle%20report.txt".utf8))])])
        let image = ClipboardEntry(items: [ClipboardItem(representations: [.init(type: NSPasteboard.PasteboardType.png.rawValue, data: Data([1, 2, 3]))])])
        let entries = [rich, file, image]
        let index = ClipboardSearchIndex()
        for query in ["CAFÉ", "👩🏽‍💻", "final needle", "report.txt", "absent"] {
            XCTAssertEqual(index.search(entries, query: query, filter: .all), entries.filter { $0.searchableText.localizedCaseInsensitiveContains(query) })
        }
        XCTAssertEqual(index.search(entries, query: "needle", filter: .text), [rich])
        XCTAssertEqual(index.search(entries, query: "needle", filter: .files), [file])
        XCTAssertEqual(index.search(entries, query: "", filter: .images), [image])
        let presentations = ClipboardPresentationCache()
        for entry in entries {
            let presentation = presentations.presentation(for: entry)
            XCTAssertEqual(presentation.title, entry.title)
            XCTAssertEqual(presentation.preview, entry.preview)
        }
    }

    func testCancelledSearchStopsBetweenEntries() {
        var extractions = 0
        let index = ClipboardSearchIndex { entry in extractions += 1; return entry.searchableText }
        let result = index.search([text("One"), text("Two"), text("Three")], query: "One", filter: .all,
                                  isCancelled: { extractions >= 1 })
        XCTAssertNil(result)
        XCTAssertEqual(extractions, 1)
    }

    func testPresentationCacheReusesResultsAndInvalidatesChangedPayloads() {
        var presentations = 0
        let cache = ClipboardPresentationCache { entry in
            presentations += 1
            return ClipboardPresentation(title: entry.title, preview: entry.preview, kind: entry.kind)
        }
        var entry = text("Original")
        let first = cache.presentation(for: entry)
        entry.isPinned = true
        entry.sourceApp = "New source"
        XCTAssertEqual(cache.presentation(for: entry), first)
        XCTAssertEqual(presentations, 1)
        entry.items = text("Replacement").items
        XCTAssertEqual(cache.presentation(for: entry).title, "Replacement")
        XCTAssertEqual(presentations, 2)
        cache.synchronize(with: [])
        XCTAssertEqual(cache.cachedByteCount, 0)
        XCTAssertEqual(cache.cachedEntryCount, 0)
    }

    func testPresentationCacheHasIndependentByteAndEntryBounds() {
        let cache = ClipboardPresentationCache(maximumCachedBytes: 40)
        for _ in 0..<300 {
            _ = cache.presentation(for: text("Title"))
            XCTAssertLessThanOrEqual(cache.cachedByteCount, 40)
            XCTAssertLessThanOrEqual(cache.cachedEntryCount, 1)
        }
        let disabled = ClipboardPresentationCache(maximumCachedBytes: 0)
        _ = disabled.presentation(for: text("Title"))
        XCTAssertEqual(disabled.cachedEntryCount, 0)
    }
}
