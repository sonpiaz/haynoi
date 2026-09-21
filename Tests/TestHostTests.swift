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
        XCTAssertTrue(RunMode.isUnderXCTest,
                      "the launch path reads this to decide whether to start the runtime")
    }

    func testTheHotkeyIsNotRegisteredWhileTestsRun() {
        XCTAssertFalse(HotkeyManager.shared.isMonitoring,
                       "a debug instance holding ⌥ steals push-to-talk from whoever is at the machine")
    }
}
