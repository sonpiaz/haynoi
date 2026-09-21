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
    static let isUnderXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
