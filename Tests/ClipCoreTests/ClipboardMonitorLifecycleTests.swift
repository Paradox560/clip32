import AppKit
import XCTest
@testable import ClipCore

final class ClipboardMonitorLifecycleTests: XCTestCase {
    @MainActor private final class Scheduler {
        var timers: [Timer] = []
        var callbacks: [@MainActor () -> Void] = []

        func schedule(_ callback: @escaping @MainActor () -> Void) -> Timer {
            let timer = Timer(timeInterval: 3_600, repeats: true) { _ in }
            timers.append(timer)
            callbacks.append(callback)
            return timer
        }
    }

    @MainActor private func withMonitor(_ body: (ClipboardMonitor, HistoryStore, NSPasteboard, Scheduler) -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clip32MonitorTests-\(UUID().uuidString)")
        let store = HistoryStore(directory: directory)
        let pasteboard = NSPasteboard.withUniqueName()
        let scheduler = Scheduler()
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard, schedulePolling: scheduler.schedule)
        defer {
            monitor.stop()
            store.flush()
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }
        body(monitor, store, pasteboard, scheduler)
    }

    @MainActor private func copy(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(text, forType: .string))
    }

    func testStartIsIdempotentAndStopCancelsScheduledCapture() async {
        await MainActor.run {
            withMonitor { monitor, store, pasteboard, scheduler in
                monitor.start()
                monitor.start()
                XCTAssertEqual(scheduler.timers.count, 1)
                XCTAssertTrue(scheduler.timers[0].isValid)
                copy("First synthetic copy", to: pasteboard)
                scheduler.callbacks[0]()
                XCTAssertEqual(store.entries.first?.searchableText, "First synthetic copy")

                monitor.stop()
                XCTAssertFalse(scheduler.timers[0].isValid)
                copy("Copy after stop", to: pasteboard)
                scheduler.callbacks[0]()
                XCTAssertEqual(store.entries.count, 1)
            }
        }
    }

    func testPauseStopsPollingAndResumeSkipsPausedCopies() async {
        await MainActor.run {
            withMonitor { monitor, store, pasteboard, scheduler in
                monitor.start()
                monitor.isPaused = true
                XCTAssertFalse(scheduler.timers[0].isValid)
                copy("Copy while paused", to: pasteboard)
                scheduler.callbacks[0]()
                monitor.captureNow() // Wake notifications must also respect pause.
                XCTAssertTrue(store.entries.isEmpty)

                monitor.isPaused = false
                XCTAssertEqual(scheduler.timers.count, 2)
                scheduler.callbacks[1]()
                XCTAssertTrue(store.entries.isEmpty)
                copy("Copy after resume", to: pasteboard)
                scheduler.callbacks[0]() // An old queued callback stays cancelled.
                XCTAssertTrue(store.entries.isEmpty)
                scheduler.callbacks[1]()
                XCTAssertEqual(store.entries.map(\.searchableText), ["Copy after resume"])
            }
        }
    }

    func testPauseBeforeStartAndStopWhilePausedRespectRequestedLifecycle() async {
        await MainActor.run {
            withMonitor { monitor, _, _, scheduler in
                monitor.isPaused = true
                monitor.start()
                XCTAssertTrue(scheduler.timers.isEmpty)
                monitor.isPaused = false
                XCTAssertEqual(scheduler.timers.count, 1)

                monitor.isPaused = true
                monitor.stop()
                monitor.isPaused = false
                XCTAssertEqual(scheduler.timers.count, 1)
                XCTAssertFalse(scheduler.timers[0].isValid)

                monitor.start()
                XCTAssertEqual(scheduler.timers.count, 2)
                XCTAssertTrue(scheduler.timers[1].isValid)
            }
        }
    }

    func testAssigningSamePauseStateDoesNotResetBaselineOrDuplicateTimers() async {
        await MainActor.run {
            withMonitor { monitor, store, pasteboard, scheduler in
                monitor.start()
                copy("Uncaptured synthetic copy", to: pasteboard)
                monitor.isPaused = false
                XCTAssertEqual(scheduler.timers.count, 1)
                scheduler.callbacks[0]()
                XCTAssertEqual(store.entries.first?.searchableText, "Uncaptured synthetic copy")
            }
        }
    }
}
