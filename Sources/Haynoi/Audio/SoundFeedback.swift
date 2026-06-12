import AVFoundation

/// Premium audio feedback with selectable themes.
/// Sound files: Resources/Sounds/{theme}/*.wav
///
/// Fix #7: Preload one AVAudioPlayer per tone at init (prepareToPlay) so the
/// first play has no disk-read latency. Separate players prevent tones from
/// clipping each other (start + stop can overlap during fast hold/release).
final class SoundFeedback {
    static let shared = SoundFeedback()

    // Separate players per tone so overlapping tones don't kill each other
    private var startPlayer: AVAudioPlayer?
    private var stopPlayer: AVAudioPlayer?
    private var cancelPlayer: AVAudioPlayer?
    private var errorPlayer: AVAudioPlayer?
    /// Played when text has been successfully inserted — a soft affirming chime
    /// distinct from the stop tone (which only signals "mic off").
    private var successPlayer: AVAudioPlayer?

    private var currentTheme: String

    private init() {
        currentTheme = UserDefaults.standard.string(forKey: "soundTheme") ?? "chime"
        preloadAll()
    }

    func reloadTheme() {
        currentTheme = UserDefaults.standard.string(forKey: "soundTheme") ?? "chime"
        preloadAll()
    }

    func playStartTone()   { startPlayer?.play(volume: 0.5) }
    func playStopTone()    { stopPlayer?.play(volume: 0.5) }
    func playCancelTone()  { cancelPlayer?.play(volume: 0.4) }
    func playErrorTone()   { errorPlayer?.play(volume: 0.35) }
    /// Soft affirming chime — falls back to the stop tone when a theme has no
    /// "success.wav" file so no existing theme silently breaks.
    func playSuccessTone() {
        if successPlayer != nil { successPlayer?.play(volume: 0.45) }
        else { stopPlayer?.play(volume: 0.35) }
    }

    // MARK: - Preload

    private func preloadAll() {
        startPlayer   = makePlayer("start")
        stopPlayer    = makePlayer("stop")
        cancelPlayer  = makePlayer("cancel")
        errorPlayer   = makePlayer("error")
        successPlayer = makePlayer("success")   // optional — graceful no-op if absent
    }

    private func makePlayer(_ name: String) -> AVAudioPlayer? {
        let themePath = "Sounds/\(currentTheme)"
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: themePath)
           ?? Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds/deep")
        else {
            NSLog("[Haynoi] Sound not found: %@/%@.wav", currentTheme, name)
            return nil
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            return player
        } catch {
            NSLog("[Haynoi] Sound preload error (%@): %@", name, error.localizedDescription)
            return nil
        }
    }
}

// MARK: - AVAudioPlayer convenience

private extension AVAudioPlayer {
    func play(volume: Float) {
        self.volume = volume
        // If already playing, rewind so overlapping calls restart cleanly
        if isPlaying { stop(); currentTime = 0 }
        play()
    }
}
