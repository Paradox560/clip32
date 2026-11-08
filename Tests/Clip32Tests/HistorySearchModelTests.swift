import AppKit
import Combine
import XCTest
import ClipCore
@testable import Clip32

final class HistorySearchModelTests: XCTestCase {
    private func text(_ value: String, id: UUID = UUID()) -> ClipboardEntry {
        ClipboardEntry(id: id, items: [ClipboardItem(representations: [
            ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(value.utf8))
        ])])
    }

    @MainActor
    private func waitUntilFinished(_ model: HistorySearchModel) async {
        let finished = expectation(description: "Latest search completed")
        let observer = model.$isSearching.filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        await fulfillment(of: [finished], timeout: 5)
        withExtendedLifetime(observer) {}
    }

    @MainActor
    func testInitialEntriesAndPresentationBecomeReadyWithoutAQuery() async {
        let model = HistorySearchModel()
        let first = text("First")
        let second = text("Second")
        model.replaceEntries([first, second])
        XCTAssertEqual(model.entries, [first, second])
        XCTAssertFalse(model.isSearching)
        let presentation = await model.presentation(for: first)
        XCTAssertEqual(presentation?.title, "First")
        model.setQuery("second")
        XCTAssertTrue(model.isSearching)
        XCTAssertTrue(model.entries.isEmpty, "Previous matches must not remain actionable")
        await waitUntilFinished(model)
        XCTAssertEqual(model.entries, [second])
    }

    @MainActor
    func testRapidQueriesAreCoalescedAndSelectionReadsDoNotRescan() async {
        var extractions = 0
        let index = ClipboardSearchIndex { entry in
            XCTAssertFalse(Thread.isMainThread)
            extractions += 1
            return entry.searchableText
        }
        let queue = DispatchQueue(label: "Clip32Tests.search.coalescing")
        queue.suspend()
        let model = HistorySearchModel(index: index, queue: queue)
        let first = text("First")
        let second = text("Last query")
        model.replaceEntries([first, second])
        for number in 0..<100 { model.setQuery("Superseded \(number)") }
        model.setQuery("Last query")
        queue.resume()
        await waitUntilFinished(model)
        XCTAssertEqual(model.entries, [second])
        XCTAssertEqual(extractions, 2)
        for _ in 0..<100 { XCTAssertEqual(model.entries.first?.id, second.id) }
        XCTAssertEqual(extractions, 2)
    }

    @MainActor
    func testInFlightOldResultsCannotReplaceANewerSourceAndQuery() async {
        let started = expectation(description: "Old extraction started")
        let gate = DispatchSemaphore(value: 0)
        var shouldBlock = true
        let index = ClipboardSearchIndex { entry in
            if shouldBlock {
                shouldBlock = false
                started.fulfill()
                _ = gate.wait(timeout: .now() + 5)
            }
            return entry.searchableText
        }
        let model = HistorySearchModel(index: index)
        let old = text("Old match")
        let newest = text("Newest match", id: old.id)
        var published: [[ClipboardEntry]] = []
        let observer = model.$entries.sink { if !$0.isEmpty { published.append($0) } }
        model.replaceEntries([old])
        model.setQuery("Old")
        await fulfillment(of: [started], timeout: 5)
        published.removeAll()
        model.replaceEntries([newest])
        model.setQuery("Newest")
        gate.signal()
        await waitUntilFinished(model)
        XCTAssertEqual(model.entries, [newest])
        XCTAssertTrue(published.allSatisfy { $0 == [newest] })
        withExtendedLifetime(observer) {}
    }

    @MainActor
    func testQueuedOldPresentationIsRejectedAfterPayloadChanges() async {
        let queue = DispatchQueue(label: "Clip32Tests.search.presentation")
        queue.suspend()
        let model = HistorySearchModel(queue: queue)
        let original = text("Original")
        let replacement = text("Replacement", id: original.id)
        model.replaceEntries([original])
        let oldPresentation = Task { await model.presentation(for: original) }
        await Task.yield()
        model.replaceEntries([replacement])
        queue.resume()
        let discarded = await oldPresentation.value
        XCTAssertNil(discarded)
        let current = await model.presentation(for: replacement)
        XCTAssertEqual(current?.title, "Replacement")
        model.replaceEntries([])
        let deleted = await model.presentation(for: replacement)
        XCTAssertNil(deleted)
    }

    @MainActor
    func testCancelledPresentationFinishesWhileTheWorkerIsSuspended() async {
        let queue = DispatchQueue(label: "Clip32Tests.search.presentationCancellation")
        queue.suspend()
        let model = HistorySearchModel(queue: queue)
        let entry = text("Synthetic copied text")
        model.replaceEntries([entry])
        let cancelled = expectation(description: "Cancelled row releases its task without waiting for the worker")
        let task = Task {
            let result = await model.presentation(for: entry)
            XCTAssertNil(result)
            cancelled.fulfill()
        }
        await Task.yield()
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        model.replaceEntries([])
        queue.resume()
        await task.value
    }

    @MainActor
    func testPinsOrderingAndClearingTheQueryUpdateMaterializedResults() async {
        let model = HistorySearchModel()
        var first = text("First match")
        let second = text("Second match")
        model.replaceEntries([first, second])
        model.setQuery("match")
        await waitUntilFinished(model)
        XCTAssertEqual(model.entries, [first, second])
        first.isPinned = true
        model.replaceEntries([second, first])
        model.setFilter(.pinned)
        await waitUntilFinished(model)
        XCTAssertEqual(model.entries, [first])
        model.setQuery("")
        XCTAssertEqual(model.entries, [first])
        model.setFilter(.all)
        XCTAssertEqual(model.entries, [second, first])
        XCTAssertFalse(model.isSearching)
    }
}
