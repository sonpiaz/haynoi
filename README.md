<h1 align="center">Haynoi</h1>

<p align="center">
  <b>Push-to-talk dictation for macOS.</b><br />
  Hold a key, speak, release — your words appear in whatever app you're typing in.
</p>

<p align="center">
  Vietnamese-first, English-friendly. Current release <b>0.3.10</b>. Powered by <a href="https://kymaapi.com">Kyma API</a>.
</p>

<p align="center">
  <a href="https://haynoi.com"><b>haynoi.com</b></a> · <a href="https://github.com/sonpiaz/haynoi/releases/latest"><b>Download for macOS</b></a>
</p>

<p align="center">
  <a href="https://github.com/sonpiaz/haynoi/blob/main/LICENSE"><img src="https://img.shields.io/github/license/sonpiaz/haynoi" alt="License" /></a>
  <a href="https://github.com/sonpiaz/haynoi/stargazers"><img src="https://img.shields.io/github/stars/sonpiaz/haynoi" alt="Stars" /></a>
  <a href="https://github.com/sonpiaz/haynoi/releases"><img src="https://img.shields.io/github/v/release/sonpiaz/haynoi?include_prereleases&label=release" alt="Release" /></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Swift-5.9-orange" alt="Swift 5.9" />
  <img src="https://img.shields.io/badge/100%25-native-blue" alt="Native" />
</p>

---

## Why Haynoi

Most dictation tools treat Vietnamese as an afterthought. **Haynoi is built for the way Vietnamese people actually speak** — tiếng Việt with English mixed in mid-sentence ("deadline", "deploy", "team marketing") — and keeps both languages intact instead of translating or mangling one of them.

- **Speaks your language(s).** Vietnamese-optimized speech-to-text that handles Vi/En code-switching — and a personal dictionary that **learns from your corrections**, so names and jargon come out right the next time without you configuring anything.
- **Works in every app.** Text is inserted directly where your cursor is — editor, browser, chat, terminal — via the Accessibility API, with clipboard fallback.
- **Nothing to paste.** Sign in once with Google. No API keys. Free tier included; Quality transcription is the default.

## How it works

```
Hold ⌥  →  speak  →  release  →  text appears
```

Two steps after you release:

1. **Listen** — Haynoi transcribes what you said (Quality by default, or Fast).
2. **Rewrite** — only in **Email / Formal** (and Auto when you're in Mail). Your spoken draft is turned into a professional message. If that polish step fails or times out, **the original transcript is still pasted** — you don't lose the words.

A floating orb shows the waveform while you hold; a layered chord confirms start and stop. Full notes: [CHANGELOG](CHANGELOG.md).

## Smart modes

| Mode | What it does |
|------|--------------|
| **Normal** | Transcribes exactly what you say (no rewrite) |
| **Clean** | Drops filler words (ừm, à, uh…) at transcription time |
| **Email / Formal** | Transcribe, then rewrite into a professional message |
| **Auto** | Picks a mode from the app you're in — Email in Mail, Clean in chat |

## It learns you

Haynoi's dictionary fills itself instead of asking you to maintain it:

- **Fix it once, it sticks.** Say "fix that" (⌃⌥) and re-dictate, edit the inserted text in place, or just repeat yourself — Haynoi notices the correction and suggests remembering it. Confirmed fixes are applied automatically from then on, and they **survive a restart**.
- **It knows when it wasn't sure.** When the transcriber hesitates on a word that *sounds like* a name you use — "Afider" for "Affitor", "Sun" for "Sơn" — that one dictation gets an extra cleanup pass with your personal terms. Confident dictations skip it, so nothing gets slower.
- **You can see if a fix is earning its keep.** Each learned word shows how often it was applied and how often you let it stand. The Dictionary header sums that up.
- **You stay in charge.** A master learning switch, a counter of what's been learned, and a one-tap "Forget all" live in Settings → Dictionary. Learning runs on transcript text only — never audio — and your dictionary never leaves your Mac.

## Features

- **Push-to-talk** — hold the left `⌥` Option key (or `⌘` / `⌃` / `fn`), release to transcribe
- **Language preference** — auto-detect by default, or pin Tiếng Việt / English
- **Failed dictations are saved** — if the network dies mid-upload, the recording stays on your Mac and retries with one click
- **Email polish never eats the draft** — if rewrite fails, the raw transcript is still inserted
- **Honest errors** — a server problem is labeled as ours. It does not tell you that you're out of words, and it does not sign you out
- **Survives real life** — AirPods disconnecting mid-sentence, permission hiccups, and flaky Wi-Fi all degrade gracefully instead of eating your dictation
- **Auto-paste** into the active app, with clipboard fallback — and your previous clipboard is restored afterwards (dictated text is also hidden from clipboard managers)
- **Other audio gets out of your way** — music and video pause and resume around your dictation; a live call or stream is dipped in volume instead, decided from what your Mac is actually playing
- **Living status orb** — recording, transcribing, success, and error each have their own state
- **Snippets** — say a trigger word, get expanded text
- **Transcription history** — searchable, stored locally, grouped by date
- **Test connection** in Settings → Account (doesn't use your word quota)
- **Premium sound feedback** — harmonic chords for start / stop / cancel / success
- **Silent auto-updates** via Sparkle, launch at login, guided onboarding

## Install

**Download** Haynoi **0.3.10** (`Haynoi.dmg`) from [haynoi.com](https://haynoi.com) or [GitHub Releases](https://github.com/sonpiaz/haynoi/releases/latest), drag it to Applications, and open it. The app is signed and notarized — no security warnings, and updates install themselves.

Prefer building from source?

```bash
git clone https://github.com/sonpiaz/haynoi.git
cd haynoi
brew install xcodegen    # if not installed
make run
```

First run, either way:

1. The onboarding wizard walks you through Microphone and Accessibility permissions — that's all Haynoi needs
2. **Sign in with Google** — one click, no passwords, nothing to paste
3. Hold the left `⌥` Option key, say something, release — the guided first dictation shows you the loop

**Runs on [Kyma API](https://kymaapi.com?utm_source=haynoi).** Kyma handles speech-to-text and rewrite for every dictation so Haynoi never holds a model key.

## Pricing

**Free: 5,000 words per week**, resetting every Monday. No card required — just Google sign-in.

**Haynoi Pro** — unlimited dictation: **$14.99 / month** or **$125.88 / year**. Upgrade in Settings → Plans & Billing; the app unlocks after payment. Manage or cancel anytime.

Two listening tiers, switchable in Settings. Email / Formal adds a rewrite pass after that:

| Step | Setting | Model | Best for |
|------|---------|-------|----------|
| **Listen** | Quality (default) | [`gpt-4o-mini-transcribe-2025-12-15`](https://kymaapi.com/models/gpt-4o-mini-transcribe-2025-12-15?utm_source=haynoi) | Vietnamese + English, noisy rooms, technical vocabulary |
| **Listen** | Fast | [`whisper-v3-turbo`](https://kymaapi.com/models/whisper-v3-turbo?utm_source=haynoi) | Clear, simple speech |
| **Rewrite** | Email / Formal only | [`gemini-2.5-flash`](https://kymaapi.com/models/gemini-2.5-flash?utm_source=haynoi) | Turn a spoken draft into a message. If this step fails, the original transcript is still pasted. |

Haynoi calls these through [Kyma API](https://kymaapi.com?utm_source=haynoi) so the app never holds a model key.

## Privacy

- **Audio** is sent to Haynoi's backend for transcription, then discarded — recordings are never stored server-side
- **Your dictionary, learned corrections, and transcription history stay on your Mac** — learning uses transcript text only, never audio, and nothing about it syncs anywhere
- Your sign-in session lives in the **macOS Keychain**
- **Anonymous usage analytics** (feature counts and timings — never your words, never transcript content) help improve the app; there's an opt-out toggle in Settings

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
│   ├── HaynoiAuth.swift          — Google sign-in via Haynoi's backend
│   └── KeychainStorage.swift     — Session storage in the macOS Keychain
├── Input/
│   ├── HotkeyManager.swift       — Global hotkey via NSEvent monitors (Accessibility)
│   └── TextInserter.swift        — AX API + clipboard text insertion
├── Transcription/
│   ├── STTProvider.swift         — Transcription, Email rewrite, correction pass
│   └── TranscriptionMode.swift   — Normal / Clean / Email / Auto modes
├── Settings/
│   └── SettingsView.swift        — Account, plans, quality, hotkey, dictionary
├── UI/                           — History list, main window, floating bar
└── System/                       — Personal dictionary + correction learning,
                                    media control, launch at login, usage stats
```

</details>

## Tech stack

| Technology | Purpose |
|-----------|---------|
| Swift 5.9 + SwiftUI | App |
| AVFoundation | Audio capture & sound synthesis |
| [Kyma API](https://kymaapi.com) | Speech-to-text and rewrite (Haynoi never holds a model key) |
| Accessibility API + NSEvent | Text insertion + global hotkey (no Input Monitoring needed) |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | Project generation |

## Related

- [Pheme](https://www.trypheme.com) — AI meeting notes for macOS, Vietnamese-optimized
- [kyma-dub](https://github.com/sonpiaz/kyma-dub) — time-aligned AI video dubbing CLI
- [Kapt](https://github.com/sonpiaz/kapt) — macOS screenshot tool with annotation & OCR

## License

MIT — see [LICENSE](LICENSE).

---

<p align="center">Built by <a href="https://github.com/sonpiaz">Son Piaz</a> · Powered by <a href="https://kymaapi.com">Kyma API</a></p>
