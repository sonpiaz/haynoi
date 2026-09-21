import Foundation

/// How this process was started.
///
/// Running the test suite launches the app as the test host. Before this was
/// checked, every run put a second Hãy Nói icon in the menu bar for a few
/// seconds, started the updater, and registered the global ⌥ push-to-talk chord
/// on whatever machine ran the tests — 22 times in one hour, on the machine the
/// owner was working on.
enum RunMode {

    /// True when XCTest launched this process as the test host.
    ///
    /// Release always answers false: a Developer ID build cannot host XCTest
    /// (see the test target in `project.yml`), and the shipped app must never
    /// switch its own features off because of an inherited environment variable.
    static func isUnderXCTest(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        #if DEBUG
        return environment["XCTestConfigurationFilePath"] != nil
        #else
        return false
        #endif
    }
}
