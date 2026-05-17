import AVFoundation

/// Premium audio feedback with selectable themes.
/// Sound files: Resources/Sounds/{theme}/*.wav
final class SoundFeedback {
    static let shared = SoundFeedback()

    private var player: AVAudioPlayer?
    private var currentTheme: String

    private init() {
        currentTheme = UserDefaults.standard.string(forKey: "soundTheme") ?? "deep"
    }

    func reloadTheme() {
        currentTheme = UserDefaults.standard.string(forKey: "soundTheme") ?? "deep"
    }

    func playStartTone()  { play("start") }
    func playStopTone()   { play("stop") }
    func playCancelTone() { play("cancel") }
    func playErrorTone()  { play("error") }

    private func play(_ name: String) {
        // Try theme-specific path first, then fallback
        let themePath = "Sounds/\(currentTheme)"
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: themePath)
           ?? Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds/deep")
        else {
            NSLog("[Haynoi] Sound not found: %@/%@.wav", currentTheme, name)
            return
        }

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.volume = 0.5
            player?.play()
        } catch {
            NSLog("[Haynoi] Sound error: %@", error.localizedDescription)
        }
    }
}
