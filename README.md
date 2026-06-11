<h1 align="center">Haynoi</h1>

<p align="center">
  <b>Push-to-talk dictation for macOS.</b><br />
  Hold a key, speak, release — your words appear in whatever app you're typing in.
</p>

<p align="center">
  Vietnamese-first, English-friendly. Powered by <a href="https://kymaapi.com">Kyma API</a>.
</p>

<p align="center">
  <a href="https://github.com/sonpiaz/haynoi/blob/main/LICENSE"><img src="https://img.shields.io/github/license/sonpiaz/haynoi" alt="License" /></a>
  <a href="https://github.com/sonpiaz/haynoi/stargazers"><img src="https://img.shields.io/github/stars/sonpiaz/haynoi" alt="Stars" /></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Swift-5.9-orange" alt="Swift 5.9" />
  <img src="https://img.shields.io/badge/100%25-native-blue" alt="Native" />
</p>

---

## Why Haynoi

Most dictation tools treat Vietnamese as an afterthought. **Haynoi is built for the way Vietnamese people actually speak** — tiếng Việt with English mixed in mid-sentence ("deadline", "deploy", "team marketing") — and keeps both languages intact instead of translating or mangling one of them.

- **Speaks your language(s).** Vietnamese-optimized speech-to-text that handles Vi/En code-switching, with a custom dictionary for names and jargon the model should never get wrong.
- **Works in every app.** Text is inserted directly where your cursor is — editor, browser, chat, terminal — via the Accessibility API, with clipboard fallback.
- **Nothing to configure.** Sign in once with a [Kyma](https://kymaapi.com) account (free credit on signup). No API keys to paste, no model menus to study.

## How it works

```
Hold ⌘  →  speak  →  release  →  text appears
```

That's the whole product. A floating bar shows the waveform while you talk; a layered chord confirms start/stop.

## Smart modes

| Mode | What it does |
|------|--------------|
| **Normal** | Transcribes exactly what you say |
| **Clean** | Drops filler words (ừm, à, uh…) |
| **Email / Formal** | Rewrites your rambling into a professional message |
| **Auto** | Picks a mode from the app you're in — formal in Mail, clean in chat |

## Features

- **Push-to-talk** — hold `⌘` (or `⌥` / `⌃` / `fn`), release to transcribe
- **Auto-paste** into the active app, with clipboard fallback
- **Custom dictionary** — teach it names and terms once, it spells them right forever
- **Snippets** — say a trigger word, get expanded text
- **Transcription history** — unlimited, stored locally, grouped by date
- **Floating bar** — minimal recording indicator with waveform and timer
- **Premium sound feedback** — harmonic chords for start / stop / cancel
- **Mute music** — auto-pauses media while you dictate
- **Menu bar + dock app**, launch at login, onboarding wizard for permissions

## Install

```bash
git clone https://github.com/sonpiaz/haynoi.git
cd haynoi
brew install xcodegen    # if not installed
make run
```

Then:

1. The onboarding wizard walks you through Microphone, Accessibility, and Input Monitoring permissions
2. Sign in with your [Kyma](https://kymaapi.com) account from Settings (`⌘,`) — free credit on signup, nothing to paste
3. Hold `⌘`, speak, release

## Quality & cost

Haynoi defaults to the highest-accuracy tier and is transparent about what dictation costs:

| Tier | Model | Per dictation* | Best for |
|------|-------|---------------|----------|
| **Quality** (default) | `gpt-4o-mini-transcribe` | ~$0.004 | Vietnamese + English, noisy rooms, technical vocabulary |
| **Fast** | `whisper-v3-turbo` | ~$0.001 | Clear, simple speech on a budget |

<sub>*One push-to-talk utterance, billed per minute through Kyma. The free signup credit covers your first ~120 dictations.</sub>

Switch tiers any time in Settings — it's one segmented control.

## Privacy

- Audio goes **only** to [Kyma API](https://kymaapi.com) for transcription, then is discarded — nothing is stored server-side beyond standard request logs
- Your Kyma credential lives in the **macOS Keychain**
- Transcription history stays **on your Mac**
- No analytics, no tracking, no telemetry in the app

## Development

```bash
make generate    # Generate Xcode project (XcodeGen)
make build       # Build via xcodebuild
make run         # Build and run
make clean       # Clean build artifacts
```

<details>
<summary><b>Project structure</b></summary>

```
Sources/Haynoi/
├── App/
│   ├── HaynoiApp.swift           — App entry, menu bar, onboarding
│   ├── AppState.swift            — Shared state, transcription history
│   └── PipelineController.swift  — Hotkey → Record → Transcribe → Insert
├── Audio/
│   ├── AudioRecorder.swift       — 16kHz mono mic capture via AVAudioEngine
│   └── SoundFeedback.swift       — Harmonic chord audio cues
├── Auth/
│   ├── KymaAuth.swift            — OAuth 2.0 + PKCE sign-in to Kyma
│   └── KeychainStorage.swift     — Credential storage
├── Input/
│   ├── HotkeyManager.swift       — Global hotkey via CGEventTap
│   └── TextInserter.swift        — AX API + clipboard text insertion
├── Transcription/
│   ├── STTProvider.swift         — Kyma transcription (quality / fast tiers)
│   └── TranscriptionMode.swift   — Normal / Clean / Email / Auto modes
├── Settings/
│   └── SettingsView.swift        — Account, quality, hotkey, dictionary
├── UI/                           — History list, main window, floating bar
└── System/                       — Launch at login, media control, usage stats
```

</details>

## Tech stack

| Technology | Purpose |
|-----------|---------|
| Swift 5.9 + SwiftUI | App |
| AVFoundation | Audio capture & sound synthesis |
| [Kyma API](https://kymaapi.com) | Speech-to-text (`gpt-4o-mini-transcribe` / `whisper-v3-turbo`) and rewrite (`gemini-2.5-flash`) |
| Accessibility API + CGEventTap | Text insertion + global hotkey |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | Project generation |

## Related

- [Pheme](https://github.com/sonpiaz/pheme) — AI meeting notes for macOS, Vietnamese-optimized
- [kyma-dub](https://github.com/sonpiaz/kyma-dub) — time-aligned AI video dubbing CLI
- [Kapt](https://github.com/sonpiaz/kapt) — macOS screenshot tool with annotation & OCR

## License

MIT — see [LICENSE](LICENSE).

---

<p align="center">Built by <a href="https://github.com/sonpiaz">Son Piaz</a> · Powered by <a href="https://kymaapi.com">Kyma API</a></p>
