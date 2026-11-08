import XCTest
@testable import Clip32

final class PasteServiceTests: XCTestCase {
    @MainActor private final class Harness {
        var changeCount = 12
        var foregroundPID: pid_t? = 99
        var isTrusted = true
        var isTerminated = false
        var activationCount = 0
        var scheduled: [() -> Void] = []
        var postedTo: [pid_t] = []
        var foregroundReads = 0
        var changeClipboardOnForegroundRead: Int?

        var target: PasteService.Target {
            PasteService.Target(processIdentifier: 42, isTerminated: { self.isTerminated }, activate: {
                self.activationCount += 1
                self.foregroundPID = 42
                return true
            })
        }

        func makeService() -> PasteService {
            var environment = PasteService.Environment()
            environment.accessibilityGranted = { self.isTrusted }
            environment.pasteboardChangeCount = { self.changeCount }
            environment.foregroundPID = {
                self.foregroundReads += 1
                if self.foregroundReads == self.changeClipboardOnForegroundRead { self.changeCount += 1 }
                return self.foregroundPID
            }
            environment.ownPID = { 99 }
            environment.schedule = { self.scheduled.append($0) }
            environment.postPaste = { self.postedTo.append($0); return true }
            return PasteService(environment: environment)
        }

        func runNext() { scheduled.removeFirst()() }
    }

    func testUnchangedClipboardPastesOnlyIntoCapturedTarget() async {
        await MainActor.run {
            let harness = Harness()
            let service = harness.makeService()
            var result: Bool?
            service.paste(to: harness.target, expectedChangeCount: 12) { result = $0 }
            XCTAssertTrue(harness.postedTo.isEmpty)
            harness.runNext()
            XCTAssertEqual(result, true)
            XCTAssertEqual(harness.postedTo, [42])
        }
    }

    func testClipboardReplacementDuringFocusWaitNeverPostsPaste() async {
        await MainActor.run {
            let harness = Harness()
            let service = harness.makeService()
            var result: Bool?
            service.paste(to: harness.target, expectedChangeCount: 12) { result = $0 }
            harness.changeCount = 13
            harness.runNext()
            XCTAssertEqual(result, false)
            XCTAssertTrue(harness.postedTo.isEmpty)
            XCTAssertTrue(harness.scheduled.isEmpty)
        }
    }

    func testClipboardIsRecheckedImmediatelyBeforePosting() async {
        await MainActor.run {
            let harness = Harness()
            let service = harness.makeService()
            // Initial foreground lookup is read one. Read two occurs after the
            // focus-wait receipt check, immediately before the final paste guard.
            harness.changeClipboardOnForegroundRead = 2
            var result: Bool?
            service.paste(to: harness.target, expectedChangeCount: 12) { result = $0 }
            harness.runNext()
            XCTAssertEqual(result, false)
            XCTAssertTrue(harness.postedTo.isEmpty)
        }
    }

    func testAlreadyStaleClipboardDoesNotStealFocus() async {
        await MainActor.run {
            let harness = Harness()
            let service = harness.makeService()
            var result: Bool?
            service.paste(to: harness.target, expectedChangeCount: 11) { result = $0 }
            XCTAssertEqual(result, false)
            XCTAssertEqual(harness.activationCount, 0)
            XCTAssertTrue(harness.scheduled.isEmpty)
            XCTAssertTrue(harness.postedTo.isEmpty)
        }
    }

    func testUserSwitchingAppsAbandonsPaste() async {
        await MainActor.run {
            let harness = Harness()
            let service = harness.makeService()
            var result: Bool?
            service.paste(to: harness.target, expectedChangeCount: 12) { result = $0 }
            harness.foregroundPID = 77
            harness.runNext()
            XCTAssertEqual(result, false)
            XCTAssertTrue(harness.postedTo.isEmpty)
            XCTAssertEqual(harness.activationCount, 1)
        }
    }

    func testMissingPermissionDoesNotActivateOrPost() async {
        await MainActor.run {
            let harness = Harness()
            harness.isTrusted = false
            let service = harness.makeService()
            var result: Bool?
            service.paste(to: harness.target, expectedChangeCount: 12) { result = $0 }
            XCTAssertEqual(result, false)
            XCTAssertEqual(harness.activationCount, 0)
            XCTAssertTrue(harness.scheduled.isEmpty)
            XCTAssertTrue(harness.postedTo.isEmpty)
        }
    }

    func testCancellationAndTerminatedTargetDoNotPost() async {
        await MainActor.run {
            for cancel in [true, false] {
                let harness = Harness()
                let service = harness.makeService()
                var result: Bool?
                service.paste(to: harness.target, expectedChangeCount: 12) { result = $0 }
                if cancel { service.cancelPendingPaste() }
                else { harness.isTerminated = true }
                harness.runNext()
                XCTAssertEqual(result, false)
                XCTAssertTrue(harness.postedTo.isEmpty)
            }
        }
    }
}
