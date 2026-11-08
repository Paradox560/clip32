import Combine
import XCTest
@testable import Clip32

final class PermissionRefreshTests: XCTestCase {
    func testUnchangedPermissionChecksDoNotPublishViewUpdates() async {
        await MainActor.run {
            let status = PermissionStatus(accessibilityGranted: false, loginEnabled: false, loginStatus: "Off")
            let model = AppModel(demo: true, permissionStatusProvider: { status })
            model.refreshPermissions()
            var notifications = 0
            let observation = model.objectWillChange.sink { notifications += 1 }
            for _ in 0..<100 { model.refreshPermissions() }
            XCTAssertEqual(notifications, 0)
            XCTAssertFalse(model.accessibilityGranted)
            XCTAssertFalse(model.loginEnabled)
            XCTAssertEqual(model.loginStatus, "Off")
            withExtendedLifetime(observation) {}
        }
    }

    func testReturningFromAccessibilitySettingsPublishesOnlyChangedAccess() async {
        await MainActor.run {
            var status = PermissionStatus(accessibilityGranted: false, loginEnabled: true, loginStatus: "Enabled")
            let model = AppModel(demo: true, permissionStatusProvider: { status })
            model.refreshPermissions()
            var notifications = 0
            let observation = model.objectWillChange.sink { notifications += 1 }

            status = PermissionStatus(accessibilityGranted: true, loginEnabled: true, loginStatus: "Enabled")
            model.refreshPermissions()
            model.refreshPermissions()

            XCTAssertTrue(model.accessibilityGranted)
            XCTAssertTrue(model.loginEnabled)
            XCTAssertEqual(model.loginStatus, "Enabled")
            XCTAssertEqual(notifications, 1)
            withExtendedLifetime(observation) {}
        }
    }

    func testLoginChangeRefreshesItsBooleanAndExplanationWithoutChangingAccess() async {
        await MainActor.run {
            var status = PermissionStatus(accessibilityGranted: true, loginEnabled: false, loginStatus: "Approval required")
            let model = AppModel(demo: true, permissionStatusProvider: { status })
            model.refreshPermissions()
            var notifications = 0
            let observation = model.objectWillChange.sink { notifications += 1 }

            status = PermissionStatus(accessibilityGranted: true, loginEnabled: true, loginStatus: "Enabled")
            model.refreshPermissions()
            model.refreshPermissions()

            XCTAssertTrue(model.accessibilityGranted)
            XCTAssertTrue(model.loginEnabled)
            XCTAssertEqual(model.loginStatus, "Enabled")
            XCTAssertEqual(notifications, 2)
            withExtendedLifetime(observation) {}
        }
    }
}
