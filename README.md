<h1 align="center">Haynoi</h1>

<p align="center">
  Push-to-talk dictation for macOS. Hold a hotkey, speak, text appears.
</p>

<p align="center">
  <a href="https://github.com/sonpiaz/yap/blob/main/LICENSE"><img src="https://img.shields.io/github/license/sonpiaz/yap" alt="License" /></a>
  <a href="https://github.com/sonpiaz/yap/stargazers"><img src="https://img.shields.io/github/stars/sonpiaz/yap" alt="Stars" /></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Swift-5.9-orange" alt="Swift 5.9" />
</p>

---

## Features

- **Push-to-talk** — Hold `⌘ Command` (or `⌥` / `⌃` / `fn`) to record, release to transcribe
- **Auto-paste** — Transcribed text is inserted directly into the active app via Accessibility API, with clipboard fallback
- **Smart modes** — Normal, Clean (removes filler words), Email (rewrites as professional text), Auto (detects app context)
- **Vietnamese + English** — Optimized for Vietnamese with mixed English support
- **Premium sound feedback** — Layered harmonic chords for start/stop/cancel cues
- **Floating bar** — Minimal top-of-screen recording indicator with app logo, waveform, and timer
- **Transcription history** — Unlimited history, persisted locally, grouped by date
- **Custom dictionary** — Add names and terms the model gets wrong
- **Snippets** — Say a trigger word, get expanded text
- **Onboarding wizard** — Guided first-launch setup for all required permissions
- **Launch at login** — Optional auto-start
- **Mute music** — Auto-pause media while dictating
- **Usage tracking** — Monthly transcription stats
- **Menu bar + dock app** — Always ready from menu bar, full window from dock icon

## Install

### Build from source

```bash
git clone https://github.com/sonpiaz/yap.git
cd yap
brew install xcodegen    # if not installed
make run
```

## Quick Start

1. Launch Haynoi — the onboarding wizard guides you through permissions
2. Go to Settings → add your [OpenAI API key](https://platform.openai.com)
3. Hold `⌘ Command` and speak
4. Release — text appears in the active app

## Requirements

- macOS 14.0 (Sonoma) or later
- OpenAI API key (uses `gpt-4o-transcribe`)
- Microphone permission
- Accessibility permission (for text insertion)
- Input Monitoring permission (for hotkey detection)

## Privacy

Haynoi sends audio data **only** to OpenAI for transcription. No audio is stored or sent anywhere else. API keys and transcription history are stored locally in UserDefaults on your Mac.

## Development

```bash
make generate    # Generate Xcode project
make build       # Build via xcodebuild
make run         # Build and run
make clean       # Clean build artifacts
```

## Project Structure

```
Sources/Haynoi/
├── App/
│   ├── HaynoiApp.swift              — App entry, menu bar, onboarding
│   ├── AppState.swift            — Shared state, transcription history
│   └── PipelineController.swift  — Hotkey → Record → Transcribe → Insert
├── Audio/
│   ├── AudioRecorder.swift       — 16kHz mono mic capture via AVAudioEngine
│   └── SoundFeedback.swift       — Harmonic chord audio cues
├── Input/
│   ├── HotkeyManager.swift       — Global hotkey via CGEventTap
│   └── TextInserter.swift        — AX API + clipboard text insertion
├── Transcription/
│   ├── STTProvider.swift         — OpenAI gpt-4o-transcribe API
│   └── TranscriptionMode.swift   — Normal / Clean / Email / Auto modes
├── Settings/
│   └── SettingsView.swift        — API key, hotkey, dictionary, permissions
├── UI/
│   ├── ContentView.swift         — History list (menu bar popover)
│   ├── MainView.swift            — Full window with sidebar
│   ├── FloatingBar.swift         — Recording indicator bar
│   └── OnboardingView.swift      — First-launch permission wizard
└── System/                       — Launch at login, media control, usage tracking
```

## Tech Stack

| Technology | Purpose |
|-----------|---------|
| [Swift 5.9](https://swift.org/) | Language |
| SwiftUI | UI framework |
| AVFoundation | Audio capture & sound synthesis |
| OpenAI API | `gpt-4o-transcribe` (STT), `gpt-4o-mini` (rewrite) |
| Accessibility API | Direct text insertion |
| CGEventTap | Global hotkey detection |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | Project generation |

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Related

- [Kapt](https://github.com/sonpiaz/kapt) — macOS screenshot tool with annotation & OCR
- [Pheme](https://github.com/sonpiaz/pheme) — AI meeting notes with real-time transcript & auto-summary
- [hidrix-tools](https://github.com/sonpiaz/hidrix-tools) — MCP server for web & social search
- [affiliate-skills](https://github.com/Affitor/affiliate-skills) — 45 AI agent skills
- [content-pipeline](https://github.com/Affitor/content-pipeline) — AI-powered LinkedIn content generation

## License

MIT — see [LICENSE](LICENSE) for details.

---

<p align="center">Built by <a href="https://github.com/sonpiaz">Son Piaz</a></p>
