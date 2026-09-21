import XCTest
@testable import Haynoi

/// Running the suite used to boot the whole app: 22 launches in one hour showed
/// up on the owner's screen as Hãy Nói blinking on and off, each one registering
/// the global ⌥ push-to-talk chord while he was working.
@MainActor
final class TestHostTests: XCTestCase {

    /// The check has to be true in exactly the situation it guards, and this test
    /// runs in that situation.
    func testTheAppKnowsItWasLaunchedByTheTestRunner() {
        XCTAssertTrue(RunMode.isHostingXCTestBundle(),
                      "everything below depends on this being the situation we are in")
    }

    /// The runtime — hotkey, pipeline, windows — must not have started. Asserting
    /// on the hotkey alone would pass for the wrong reason on a machine where the
    /// debug bundle id was never granted accessibility, so read the flag the
    /// launch path sets only after it is past the gate.
    func testTheRuntimeIsNotStartedWhileTestsRun() throws {
        let delegate = try XCTUnwrap(AppDelegate.shared,
                                     "no delegate means this test checked nothing")
        XCTAssertFalse(delegate.didStartRuntime,
                       "the test host must not start the app's runtime")
        XCTAssertFalse(HotkeyManager.shared.isMonitoring,
                       "a debug instance holding ⌥ steals push-to-talk from whoever is at the machine")
    }

    /// Two questions, deliberately answered differently. Whether a test runner
    /// started us is a fact, and the code deciding where the owner's files live
    /// must get the careful answer in every configuration. Whether to refuse to
    /// start the runtime is a policy, and Release always says no.
    func testTheFactHoldsEverywhereAndThePolicyOnlyInDebug() {
        let asTestHost = ["XCTestConfigurationFilePath": "/tmp/x"]
        XCTAssertFalse(RunMode.isHostingXCTestBundle(environment: [:]), "no variable, no test run")
        XCTAssertTrue(RunMode.isHostingXCTestBundle(environment: asTestHost))
        XCTAssertFalse(RunMode.shouldSkipRuntime(environment: [:]))
        #if DEBUG
        XCTAssertTrue(RunMode.shouldSkipRuntime(environment: asTestHost))
        #else
        XCTAssertFalse(RunMode.shouldSkipRuntime(environment: asTestHost),
                       "a release build starts its runtime whatever the environment says")
        #endif
    }

    /// The dictionary decides where the owner's file lives from the fact, so it
    /// stays careful even in a configuration where the runtime would start.
    func testTheDictionaryReadsTheFactNotThePolicy() {
        XCTAssertTrue(PersonalDictionary.isRunningTests(
            environment: ["XCTestConfigurationFilePath": "/tmp/x"]))
        XCTAssertFalse(PersonalDictionary.isRunningTests(environment: [:]))
    }

    /// Both functions answer the same question in Debug, so no behaviour test can
    /// tell which one the launch path calls — and it called the wrong one once,
    /// which quietly removed the promise that a shipped build never switches
    /// itself off. Read the source instead, across every file: the same mistake
    /// made anywhere else carries the same bug. Matching is deliberately blunt —
    /// a comment naming the fact function turns this red, which is the price of a
    /// check that cannot be talked around.
    func testOnlyTheDataLayerAsksTheFactAndThePolicyHasFourCallers() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let mayAskTheFact = ["RunMode.swift", "PersonalDictionary.swift"]
        var policyCallSites = 0

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "no sources found at \(sources.path)")

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            policyCallSites += source.components(separatedBy: "RunMode.shouldSkipRuntime(").count - 1
            guard !mayAskTheFact.contains(file.lastPathComponent) else { continue }
            XCTAssertFalse(source.contains("isHostingXCTestBundle"),
                           "\(file.lastPathComponent) asks the fact; only the data layer may")
        }

        XCTAssertEqual(policyCallSites, 4,
                       "the updater, the menu bar scene and both launch callbacks — four, and no more")
    }
}
