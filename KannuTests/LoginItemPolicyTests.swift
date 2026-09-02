import XCTest

/// Pins the rules that keep "launch at login" honest: a one-time default that never overrides
/// the user, and a repair that only fires when the app actually moved.
final class LoginItemPolicyTests: XCTestCase {

    // MARK: - Auto-enable (the one-time default)

    func testAutoEnablesOnceOnAFreshInstall() {
        XCTAssertTrue(LoginItemPolicy.shouldAutoEnable(
            isInstalled: true, hasAutoEnabledBefore: false, isCurrentlyRegistered: false
        ))
    }

    func testNeverAutoEnablesTwice() {
        // THE rule that protects the user's choice: once the default has been applied, an opt-out
        // must survive every future launch.
        XCTAssertFalse(LoginItemPolicy.shouldAutoEnable(
            isInstalled: true, hasAutoEnabledBefore: true, isCurrentlyRegistered: false
        ))
    }

    func testDoesNotAutoEnableWhenAlreadyRegistered() {
        XCTAssertFalse(LoginItemPolicy.shouldAutoEnable(
            isInstalled: true, hasAutoEnabledBefore: false, isCurrentlyRegistered: true
        ))
    }

    func testNeverAutoEnablesFromAnUninstalledCopy() {
        // Registering from DerivedData or ~/Downloads pins that path forever.
        XCTAssertFalse(LoginItemPolicy.shouldAutoEnable(
            isInstalled: false, hasAutoEnabledBefore: false, isCurrentlyRegistered: false
        ))
    }

    // MARK: - Repair (stale path only)

    func testRepairsWhenTheInstallPathChanged() {
        XCTAssertTrue(LoginItemPolicy.shouldRepairRegistration(
            isInstalled: true, isEnabled: true,
            currentPath: "/Applications/Kannu.app",
            lastRegisteredPath: "/Users/x/Downloads/Kannu.app"
        ))
    }

    func testDoesNotRepairWhenThePathIsUnchanged() {
        // The every-boot teardown this replaces is what made a transient failure permanent.
        XCTAssertFalse(LoginItemPolicy.shouldRepairRegistration(
            isInstalled: true, isEnabled: true,
            currentPath: "/Applications/Kannu.app",
            lastRegisteredPath: "/Applications/Kannu.app"
        ))
    }

    func testRepairNeverEnablesADisabledItem() {
        XCTAssertFalse(LoginItemPolicy.shouldRepairRegistration(
            isInstalled: true, isEnabled: false,
            currentPath: "/Applications/Kannu.app",
            lastRegisteredPath: "/somewhere/else/Kannu.app"
        ))
    }

    func testDoesNotRepairFromAnUninstalledCopy() {
        XCTAssertFalse(LoginItemPolicy.shouldRepairRegistration(
            isInstalled: false, isEnabled: true,
            currentPath: "/tmp/build/Kannu.app",
            lastRegisteredPath: "/Applications/Kannu.app"
        ))
    }

    func testFirstEverRegistrationCountsAsAChange() {
        XCTAssertTrue(LoginItemPolicy.shouldRepairRegistration(
            isInstalled: true, isEnabled: true,
            currentPath: "/Applications/Kannu.app",
            lastRegisteredPath: ""
        ))
    }
}
