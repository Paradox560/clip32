import ServiceManagement
import XCTest
@testable import Clip32

@MainActor
private final class MockLoginItemService: LoginItemServicing {
    var status: SMAppService.Status
    var registrationCount = 0
    var unregistrationCount = 0
    var registrationError: Error?
    var unregistrationError: Error?

    init(status: SMAppService.Status) { self.status = status }

    func register() throws {
        registrationCount += 1
        if let registrationError { throw registrationError }
        status = .enabled
    }

    func unregister() throws {
        unregistrationCount += 1
        if let unregistrationError { throw unregistrationError }
        status = .notRegistered
    }
}

final class LoginItemManagerTests: XCTestCase {
    private static let attemptedKey = "Clip32.loginItemRegistrationAttempted"
    private static let desiredKey = "Clip32.launchAtLoginDesired"

    private func withDefaults(_ body: @MainActor (UserDefaults) throws -> Void) async throws {
        try await MainActor.run {
            let suite = "Clip32LoginTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            try body(defaults)
        }
    }

    func testFirstLaunchEnablesLoginExactlyOnce() async throws {
        try await withDefaults { defaults in
            let service = MockLoginItemService(status: .notRegistered)
            let manager = LoginItemManager(defaults: defaults, service: service, isAppBundle: true)
            try manager.enableOnFirstLaunch()
            try manager.enableOnFirstLaunch()
            XCTAssertEqual(service.registrationCount, 1)
            XCTAssertTrue(manager.isEnabled)
            XCTAssertTrue(defaults.bool(forKey: Self.attemptedKey))
            XCTAssertEqual(defaults.object(forKey: Self.desiredKey) as? Bool, true)
        }
    }

    func testLegacyAttemptWithMissingRegistrationIsRepaired() async throws {
        try await withDefaults { defaults in
            defaults.set(true, forKey: Self.attemptedKey)
            let service = MockLoginItemService(status: .notFound)
            let manager = LoginItemManager(defaults: defaults, service: service, isAppBundle: true)
            try manager.enableOnFirstLaunch()
            XCTAssertEqual(service.registrationCount, 1)
            XCTAssertTrue(manager.isEnabled)
            XCTAssertEqual(defaults.object(forKey: Self.desiredKey) as? Bool, true)
        }
    }

    func testEnabledPreferenceRepairsMissingRegistrationAfterReplacement() async throws {
        try await withDefaults { defaults in
            defaults.set(true, forKey: Self.attemptedKey)
            defaults.set(true, forKey: Self.desiredKey)
            let service = MockLoginItemService(status: .notFound)
            let manager = LoginItemManager(defaults: defaults, service: service, isAppBundle: true)
            try manager.enableOnFirstLaunch()
            XCTAssertEqual(service.registrationCount, 1)
            XCTAssertTrue(manager.isEnabled)
        }
    }

    func testExplicitOffPreferenceSurvivesNotFoundAfterReplacement() async throws {
        try await withDefaults { defaults in
            let service = MockLoginItemService(status: .enabled)
            let manager = LoginItemManager(defaults: defaults, service: service, isAppBundle: true)
            try manager.setEnabled(false)
            XCTAssertEqual(service.unregistrationCount, 1)
            XCTAssertEqual(defaults.object(forKey: Self.desiredKey) as? Bool, false)
            service.status = .notFound
            try manager.enableOnFirstLaunch()
            XCTAssertEqual(service.registrationCount, 0)
            XCTAssertFalse(manager.isEnabled)
        }
    }

    func testDisablingAlreadyMissingServiceStillRecordsExplicitOff() async throws {
        try await withDefaults { defaults in
            let service = MockLoginItemService(status: .notFound)
            let manager = LoginItemManager(defaults: defaults, service: service, isAppBundle: true)
            try manager.setEnabled(false)
            try manager.enableOnFirstLaunch()
            XCTAssertEqual(service.registrationCount, 0)
            XCTAssertEqual(service.unregistrationCount, 0)
            XCTAssertEqual(defaults.object(forKey: Self.desiredKey) as? Bool, false)
        }
    }

    func testExternalNotRegisteredStateIsNotOverriddenAfterAnAttempt() async throws {
        try await withDefaults { defaults in
            defaults.set(true, forKey: Self.attemptedKey)
            defaults.set(true, forKey: Self.desiredKey)
            let service = MockLoginItemService(status: .notRegistered)
            let manager = LoginItemManager(defaults: defaults, service: service, isAppBundle: true)
            try manager.enableOnFirstLaunch()
            XCTAssertEqual(service.registrationCount, 0)
            XCTAssertFalse(manager.isEnabled)
        }
    }

    func testPendingApprovalDoesNotRegisterAgain() async throws {
        try await withDefaults { defaults in
            let service = MockLoginItemService(status: .requiresApproval)
            let manager = LoginItemManager(defaults: defaults, service: service, isAppBundle: true)
            try manager.enableOnFirstLaunch()
            try manager.enableOnFirstLaunch()
            try manager.setEnabled(true)
            XCTAssertEqual(service.registrationCount, 0)
            XCTAssertTrue(manager.requiresApproval)
            XCTAssertFalse(manager.isEnabled)
        }
    }

    func testRegistrationFailurePropagatesWithoutRecordingSuccess() async throws {
        try await withDefaults { defaults in
            let service = MockLoginItemService(status: .notFound)
            let failure = NSError(domain: "Clip32Tests", code: 42)
            service.registrationError = failure
            let manager = LoginItemManager(defaults: defaults, service: service, isAppBundle: true)
            XCTAssertThrowsError(try manager.enableOnFirstLaunch()) { error in
                XCTAssertEqual(error as NSError, failure)
            }
            XCTAssertFalse(manager.isEnabled)
            XCTAssertNil(defaults.object(forKey: Self.desiredKey))
            service.registrationError = nil
            try manager.enableOnFirstLaunch()
            XCTAssertTrue(manager.isEnabled)
        }
    }

    func testUnregistrationFailurePreservesPreviousPreference() async throws {
        try await withDefaults { defaults in
            defaults.set(true, forKey: Self.desiredKey)
            let service = MockLoginItemService(status: .enabled)
            service.unregistrationError = NSError(domain: "Clip32Tests", code: 43)
            let manager = LoginItemManager(defaults: defaults, service: service, isAppBundle: true)
            XCTAssertThrowsError(try manager.setEnabled(false))
            XCTAssertEqual(defaults.object(forKey: Self.desiredKey) as? Bool, true)
            XCTAssertTrue(manager.isEnabled)
        }
    }

    func testBareExecutableCannotRegisterLoginItem() async throws {
        try await withDefaults { defaults in
            let service = MockLoginItemService(status: .notRegistered)
            let manager = LoginItemManager(defaults: defaults, service: service, isAppBundle: false)
            XCTAssertThrowsError(try manager.enableOnFirstLaunch())
            XCTAssertEqual(service.registrationCount, 0)
            XCTAssertFalse(defaults.bool(forKey: Self.attemptedKey))
        }
    }
}
