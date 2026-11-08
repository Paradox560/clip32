import AppKit
import XCTest
@testable import ClipCore

final class ClipboardPresentationTests: XCTestCase {
    private func entry(_ text: String) -> ClipboardEntry {
        ClipboardEntry(items: [ClipboardItem(representations: [ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))])])
    }

    func testLargeTextHasBoundedDisplayAndKeepsFullSearchablePayload() {
        let text = String(repeating: "A", count: 2 * 1_024 * 1_024) + " search-at-the-end"
        let item = entry(text)
        XCTAssertEqual(item.title, String(repeating: "A", count: 140))
        XCTAssertEqual(item.preview, String(repeating: "A", count: 800))
        XCTAssertEqual(item.searchableText, text)
        XCTAssertEqual(item.items[0].data(for: .string), Data(text.utf8))
    }

    func testTitleUsesFirstMeaningfulLineAndCollapsesWhitespace() {
        let item = entry("\n\r\n \t\n  Hello\t  clipboard \u{00a0} world \r\nSecond line")
        XCTAssertEqual(item.title, "Hello clipboard world")
        XCTAssertTrue(item.preview.contains("Second line"))
    }

    func testDisplayPreservesUnicodeGraphemesAndScalarBoundaries() {
        let grapheme = "👩🏽‍💻e\u{301}"
        let text = String(repeating: grapheme, count: 5_000)
        let item = entry(text)
        XCTAssertEqual(item.title, String(text.prefix(140)))
        XCTAssertEqual(item.preview, String(text.prefix(800)))
        XCTAssertFalse(item.title.contains("\u{fffd}"))
        XCTAssertFalse(item.preview.contains("\u{fffd}"))
    }

    func testLongWhitespacePrefixHasSafeFallbackWithoutChangingContent() {
        let text = String(repeating: " ", count: 20_000) + "Tail"
        let item = entry(text)
        XCTAssertEqual(item.title, "Formatted text")
        XCTAssertEqual(item.preview.count, 800)
        XCTAssertEqual(item.searchableText, text)
    }

    func testInvalidUTF8FallsBackToOtherRepresentation() {
        let item = ClipboardEntry(items: [ClipboardItem(representations: [
            ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data([0xff, 0xfe, 0x80])),
            ClipboardRepresentation(type: NSPasteboard.PasteboardType.URL.rawValue, data: Data("https://example.com/".utf8))
        ])])
        XCTAssertEqual(item.title, "https://example.com/")
        XCTAssertEqual(item.preview, "https://example.com/")
        XCTAssertEqual(item.searchableText, "https://example.com/")
    }

    func testPreviewKeepsMultipleTextItemsAndNewlines() {
        let item = ClipboardEntry(items: [entry("First").items[0], entry("Second\nThird").items[0]])
        XCTAssertEqual(item.title, "First")
        XCTAssertEqual(item.preview, "First\nSecond\nThird")
        XCTAssertEqual(item.searchableText, "First\nSecond\nThird")
    }

    func testRichTextFallbackKeepsItsExistingTextContent() throws {
        let attributed = NSAttributedString(string: "Formatted sample\nNext line")
        let data = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let item = ClipboardEntry(items: [ClipboardItem(representations: [ClipboardRepresentation(type: NSPasteboard.PasteboardType.rtf.rawValue, data: data)])])
        XCTAssertEqual(item.title, "Formatted sample")
        XCTAssertEqual(item.preview, "Formatted sample\nNext line")
        XCTAssertEqual(item.searchableText, "Formatted sample\nNext line")
    }
}
