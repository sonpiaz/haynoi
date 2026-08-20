import XCTest
@testable import Haynoi

/// The pause-vs-duck policy, tested as a pure function of what the Mac is
/// playing. No mic, no call, no sound card — every branch of the decision that
/// runs when you press the dictation key.
final class MediaPolicyTests: XCTestCase {

    private func process(
        _ bundleID: String?,
        pid: pid_t = 1,
        playing: Bool = false,
        capturing: Bool = false
    ) -> SystemAudio.AudioProcess {
        SystemAudio.AudioProcess(pid: pid, bundleID: bundleID, isPlaying: playing, isCapturing: capturing)
    }

    private func plan(
        _ processes: [SystemAudio.AudioProcess],
        scriptableAppRunning: Bool = false
    ) -> MediaController.Scene {
        MediaController.Scene.plan(
            processes: processes,
            myPID: 999,
            myBundleID: "com.sonpiaz.haynoi",
            scriptableAppRunning: scriptableAppRunning
        )
    }

    // MARK: - Nothing playing

    func testSilenceDoesNothing() {
        // Apps open but idle: Spotify sitting there, Zoom sitting there.
        let scene = plan([
            process("com.spotify.client", pid: 1),
            process("us.zoom.xos", pid: 2),
        ], scriptableAppRunning: true)

        XCTAssertFalse(scene.hasPlayback, "No audio playing — Haynoi must not touch anything")
        XCTAssertFalse(scene.useMediaKey)
        XCTAssertFalse(scene.hasLiveAudio)
        XCTAssertTrue(scene.appsToPause.isEmpty)
    }

    /// The regression that motivated the rewrite: Zoom open all day used to
    /// suppress pausing entirely, so music kept playing over every dictation.
    func testIdleZoomDoesNotBlockPausingMusic() {
        let scene = plan([
            process("us.zoom.xos", pid: 2),                       // open, silent
            process("com.spotify.client", pid: 3, playing: true),  // actually playing
        ], scriptableAppRunning: true)

        XCTAssertEqual(scene.appsToPause, ["Spotify"])
        XCTAssertFalse(scene.hasLiveAudio, "An open Zoom is not a meeting")
    }

    // MARK: - The conversation test

    func testPlayingAndCapturingIsDuckedNotPaused() {
        let scene = plan([process("us.zoom.xos", pid: 2, playing: true, capturing: true)])

        XCTAssertTrue(scene.hasLiveAudio, "A live call must be ducked")
        XCTAssertTrue(scene.appsToPause.isEmpty, "A live call must never be paused")
        XCTAssertFalse(scene.useMediaKey)
    }

    /// Google Meet in a browser: audio out and mic in land on different helper
    /// processes of the same app, so identity has to collapse them.
    func testBrowserCallIsRecognisedAcrossHelperProcesses() {
        let scene = plan([
            process("com.google.Chrome.helper", pid: 10, playing: true),
            process("com.google.Chrome.helper.Renderer", pid: 11, capturing: true),
        ])

        XCTAssertTrue(scene.hasLiveAudio, "Meet in Chrome is a call, not a video")
        XCTAssertFalse(scene.useMediaKey, "Never send a media key at a live call")
    }

    /// Same browser, no mic in use — that is a video, and it gets paused.
    func testBrowserVideoUsesMediaKey() {
        let scene = plan([process("com.google.Chrome.helper", pid: 10, playing: true)])

        XCTAssertTrue(scene.useMediaKey)
        XCTAssertFalse(scene.hasLiveAudio)
        XCTAssertEqual(scene.pauseTargets, ["com.google.Chrome"])
    }

    // MARK: - Mixed scenes

    func testCallAndMusicTogetherDucksCallAndPausesMusic() {
        let scene = plan([
            process("us.zoom.xos", pid: 2, playing: true, capturing: true),
            process("com.spotify.client", pid: 3, playing: true),
        ], scriptableAppRunning: true)

        XCTAssertTrue(scene.hasLiveAudio, "Zoom gets ducked")
        XCTAssertEqual(scene.appsToPause, ["Spotify"], "Spotify gets paused")
    }

    /// With Spotify running, the media key is ambiguous — it can start the
    /// paused player instead of stopping the browser. Duck the leftovers.
    func testMediaKeyIsAvoidedWhenAScriptablePlayerIsRunning() {
        let scene = plan([
            process("com.google.Chrome.helper", pid: 10, playing: true),
        ], scriptableAppRunning: true)

        XCTAssertFalse(scene.useMediaKey, "Media key could resume a paused Spotify")
        XCTAssertTrue(scene.duckRemainingMedia)
    }

    // MARK: - Noise filtering

    func testSiriListenerIsNotTreatedAsPlayback() {
        // CoreSpeech reports output AND input constantly; counting it would make
        // Haynoi believe a call is in progress on every single dictation.
        let scene = plan([process("com.apple.CoreSpeech", pid: 5, playing: true, capturing: true)])

        XCTAssertFalse(scene.hasPlayback)
        XCTAssertFalse(scene.hasLiveAudio)
    }

    func testHaynoiOwnAudioIsIgnored() {
        // Our own start tone plays through the same device while we capture the
        // mic — the textbook false "live call".
        let scene = plan([
            process("com.sonpiaz.haynoi", pid: 999, playing: true, capturing: true),
            process(nil, pid: 42, playing: true), // a CLI player, no bundle id
        ])

        XCTAssertFalse(scene.hasLiveAudio)
        XCTAssertEqual(scene.pauseTargets, ["pid:42"], "Bundle-less players are still real playback")
        XCTAssertTrue(scene.useMediaKey)
    }
}
