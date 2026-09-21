import XCTest
@testable import Haynoi

/// Running the suite used to boot the whole app: 22 launches in one hour showed
/// up on Son's screen as Hãy Nói blinking on and off, each one registering the
/// global ⌥ push-to-talk chord while he was working.
@MainActor
final class TestHostTests: XCTestCase {

    /// The check has to be true in exactly the situation it guards, and this test
    /// runs in that situation.
    func testTheAppKnowsItWasLaunchedByTheTestRunner() {
        XCTAssertTrue(RunMode.isUnderXCTest(),
                      "the launch path reads this to decide whether to start the runtime")
    }

    /// The runtime — hotkey, pipeline, windows — must not have started. Asserting
    /// on the hotkey alone would pass for the wrong reason on a machine where the
    /// debug bundle id was never granted accessibility, so read the flag the
    /// launch path sets only after it has gone past the gate.
    func testTheRuntimeIsNotStartedWhileTestsRun() {
        XCTAssertFalse(AppDelegate.shared?.didStartRuntime ?? false,
                       "the test host must not start the app's runtime")
        XCTAssertFalse(HotkeyManager.shared.isMonitoring,
                       "a debug instance holding ⌥ steals push-to-talk from whoever is at the machine")
    }

    /// Release must never switch itself off because of an inherited variable.
    func testTheFlagIsOnlyEverTrueInADebugTestRun() {
        XCTAssertFalse(RunMode.isUnderXCTest(environment: [:]),
                       "no variable, no test run")
        #if DEBUG
        XCTAssertTrue(RunMode.isUnderXCTest(environment: ["XCTestConfigurationFilePath": "/tmp/x"]))
        #else
        XCTAssertFalse(RunMode.isUnderXCTest(environment: ["XCTestConfigurationFilePath": "/tmp/x"]),
                       "a release build answers false whatever the environment says")
        #endif
    }
}
