import Foundation

/// How this process was started.
///
/// Running the test suite launches the app as the test host. Before this was
/// checked, every run put a second Hãy Nói icon in the menu bar for a few
/// seconds, started the updater, and registered the global ⌥ push-to-talk chord
/// on whatever machine ran the tests — 22 times in one hour, on the machine the
/// owner was working on.
enum RunMode {

    /// Whether XCTest launched this process as the test host. A fact, true in any
    /// configuration — decisions about *the owner's files* must be careful in all
    /// of them, so they read this one.
    ///
    /// Named apart from `shouldSkipRuntime` on purpose: the launch path read the
    /// fact by mistake once, which silently dropped the guarantee that a shipped
    /// build never switches itself off.
    static func isHostingXCTestBundle(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    /// Whether to skip starting the app's runtime — menu bar item, updater,
    /// hotkey, pipeline, windows. A policy, and only ever true in Debug: a
    /// Developer ID build cannot host XCTest (see the test target in
    /// `project.yml`), and the shipped app must never switch its own features off
    /// because of an inherited environment variable.
    static func shouldSkipRuntime(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        #if DEBUG
        return isHostingXCTestBundle(environment: environment)
        #else
        return false
        #endif
    }
}
