# Changelog

All notable changes to Haynoi are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.4] - 2026-06-12

### Added
- A "Test connection" button in Settings → Account. It checks whether
  your dictation can actually reach our servers on each network route
  and tells you in plain language what's wrong — a blocked upload, an
  expired sign-in, or no credits. It's free: it doesn't transcribe.

## [0.3.3] - 2026-06-12

### Fixed
- Dictation on slow or congested networks (reported across Vietnam):
  recordings are now uploaded in a compressed format about 5× smaller,
  so the audio reaches the server even where the previous larger upload
  stalled. This is the real fix behind the "Something went wrong" errors
  some users saw after speaking.

## [0.3.2] - 2026-06-12

### Changed
- The network route check is now featherweight — it pings a 93-byte
  health endpoint instead of downloading the full model list, so
  checking your routes uses almost no data.

## [0.3.1] - 2026-06-12

### Changed
- Haynoi re-checks its network routes whenever your connection changes
  (new Wi-Fi, VPN on/off, waking up somewhere else) — not just at
  launch. Long-running sessions always dictate over the current best
  route.

## [0.3.0] - 2026-06-12

### Changed
- Smarter networking: Haynoi probes its API routes at launch and
  dictates over the fastest one that works from YOUR network. If a
  route stalls mid-dictation, the next one races in parallel after 4
  seconds — the winner is remembered, so a bad network costs you a few
  seconds once, not on every sentence.

## [0.2.9] - 2026-06-12

### Changed
- When a network route stalls, Haynoi now moves to the next route in 30
  seconds instead of 90 — a rescued dictation lands in under a minute.

## [0.2.8] - 2026-06-12

### Fixed
- A third automatic upload route for networks where both standard paths
  stall — dictation now tries a completely independent network edge
  before giving up.

## [0.2.7] - 2026-06-12

### Fixed
- Dictation now works on networks where the direct upload path stalls
  (reported from Vietnam): if the audio upload fails, Haynoi
  automatically retries through an alternate route. If you kept seeing
  "Something went wrong" after speaking, this is for you.

## [0.2.6] - 2026-06-12

### Fixed
- The Settings gear and Sign in buttons in the menu bar panel actually
  open Settings now — they had been calling a retired macOS hook that
  silently did nothing.

## [0.2.5] - 2026-06-12

### Changed
- Haynoi is now a menu-bar app: no Dock icon while you work — it appears
  only when the main window is open. Dictation works whenever the app is
  running.
- The menu bar panel shows your 5 most recent dictations, each with a
  copy button right on the row.
- Removed the panel's Mode and Settings rows, which opened nothing.
  Settings lives in the main window.

## [0.2.4] - 2026-06-12

### Fixed
- Clicking the menu bar icon now actually shows the panel — it was
  opening collapsed to a sliver of 10 pixels, which looked like nothing
  happened at all.

### Changed
- Insights got a cleaner layout: one headline, then words / pace /
  streaks together on a single row of cards matching the History page,
  the activity heatmap, and where your words go. Duplicate app rows are
  merged, and the redundant footer is gone.

## [0.2.3] - 2026-06-12

### Fixed
- The app no longer feels sluggish after dictating: an internal audio
  level signal kept re-rendering the interface ~47 times a second for a
  minute after each dictation. Scrolling, switching sections, and the
  menu bar panel are smooth again.
- Long histories scroll smoothly — rows are now built only as they come
  into view.

### Changed
- The copy button is back on every history row — always visible, and the
  row never shifts. Delete stays in the right-click menu.
- Removed the Recent section — it duplicated History.

## [0.2.2] - 2026-06-12

### Changed
- History rows are completely still now: no more layout shift on hover
  and no language badge. Copy and Delete live in the right-click menu;
  selecting text directly still works.

## [0.2.1] - 2026-06-12

### Changed
- The press registers almost immediately: the hold-confirmation window
  dropped from 200ms to 100ms, and the start chime now fires within a
  few hundredths of a second of the microphone going live.
- The indicator moved to the top-center of the screen and wears a new
  dark cosmic capsule — deep-space gradient, hairline border, and an
  aurora halo that swells only with your voice.
- Quieter by default: exactly two tones per dictation (press and
  release). The "N words" chip still appears — silently. The success
  chime is now opt-in in Settings → Sounds.

### Removed
- The violet dot while transcribing. Release is quiet until the words
  chip springs in.

## [0.2.0] - 2026-06-12

### Changed
- A new recording indicator: Trail — a Voice-Memos style scrolling
  waveform where your last second of speech stays visible. Silence is a
  flat line of dashes; the trail only ever moves with your voice.
- A new default sound theme: Chime — a gentle bell pair on start and
  stop. The previous themes are still available in Settings → Sounds.

### Added
- When your text lands, the indicator shows a small "N words" chip —
  confirmation plus a tiny reward. A subtle chime plays with it; turn
  either off in Settings → Sounds.

## [0.1.9] - 2026-06-12

### Fixed
- Dictation now starts the instant you press the key: the microphone engine
  stays warm between dictations instead of cold-starting every time, so the
  multi-second wait (especially on Bluetooth headsets) is gone.
- Your first words are never clipped again — Haynoi keeps a 300ms pre-roll
  from just before recording begins.
- The start tone is honest now: it plays exactly when the microphone is
  truly live. When you hear it, speak.
- The hotkey hint showed "Option + Space"; recording is hold left Option
  alone. The hint now reads "Left Option" (and haynoi.com says so too).

### Changed
- The recording waveform follows your real voice: still while you are
  silent, moving while you speak — in both the floating orb and the menu
  bar panel.
- Text lands ~250ms faster when dictating into the app you are already in.

## [0.1.8] - 2026-06-11

### Added
- A livelier listening indicator: while you speak, the floating orb shows
  aurora voice bars that react to your voice, with a soft ring pulsing outward.
- New users are guided to unlock their free credit — if you sign up and
  haven't verified your email yet, Haynoi tells you to check your inbox
  instead of failing your first dictation. Tip: signing in with Google
  activates your free credit instantly.

### Changed
- Updates now install silently in the background and check hourly, so fixes
  reach you without any prompts.
- The credit balance refreshes when you open the menu so it's never stale.

## [0.1.7] - 2026-06-11

### Fixed
- The listening orb now appears the instant you hold the key, so you can see
  Haynoi is hearing you — previously it only showed up after you finished.
- Removed the extra "done" sound after transcription; releasing the key now
  plays a single tone instead of two.

## [0.1.6] - 2026-06-11

### Fixed
- Fixed a crash that could happen the moment a dictation was inserted: the
  keyboard-layout lookup now runs on the main thread, so paste no longer
  trips a system assertion. Dictation now reliably types your words into the
  active app.

## [0.1.5] - 2026-06-11

### Changed
- The interface is now light and white-gray by default, with a clean left
  sidebar (History, Insights, Recent, Modes, About), a row of at-a-glance
  stats, and a tidy history list that shows which app each dictation went to.
  Prefer dark? A new Theme setting (System / Light / Dark) is in Settings.
- The default push-to-talk key is now the left Option (⌥) key — hold it and
  speak. You can still pick Command, Control, or Fn in Settings.

## [0.1.4] - 2026-06-11

### Changed
- Setup is now simpler: Haynoi no longer asks for Input Monitoring. The hotkey
  is detected through Accessibility, the same permission Haynoi already uses to
  type for you — so first-run needs just Microphone and Accessibility, and both
  take effect immediately with no app restart.

## [0.1.3] - 2026-06-11

### Changed
- A calmer, lighter interface: Haynoi moves to a clean white-gray design with
  a single accent color, keeping the aurora only for the recording orb. The
  menubar popover is now the heart of the app — start a dictation, see your
  balance, and grab your last result without opening a window.

### Added
- Onboarding that teaches as it goes: a side-by-side guide shows you exactly
  where to flip each permission switch, a live microphone test, and a hotkey
  tryout before your first real dictation.
- A one-click Relaunch step if macOS needs a restart to finish granting
  Accessibility.

### Fixed
- A branded installer window with an arrow showing where to drag Haynoi.

## [0.1.2] - 2026-06-11

### Fixed
- Drag-to-grant now works on the first try: the icon drags like a real
  Finder item, System Settings accepts the drop, and the step advances the
  moment you flip the switch. No more double-clicking, no more hunting for
  the app by hand.

## [0.1.1] - 2026-06-11

### Added
- Drag-to-grant permissions: during onboarding, drag the Haynoi icon straight
  into the System Settings list that opens beside the window — no more hunting
  for the app by name. Settings → Permissions gains matching Fix buttons.
- Insights: a private scoreboard for your voice — lifetime words with human
  comparisons, honest words-per-minute, current and longest streaks, a 16-week
  activity heatmap, where your words go by app, and quiet milestones.

### Fixed
- Words-per-minute no longer shows impossible numbers when older history
  predates duration tracking.

## [0.1.0] - 2026-06-11

Initial public release.

### Added
- Push-to-talk dictation triggered by holding `⌘ Command` (or `⌥` / `⌃` / `fn`)
- Cloud transcription via Kyma API — Quality (default) and Fast tiers
- Vietnamese + English mixed transcription, with a language preference
  (Auto-detect / Tiếng Việt / English — Auto by default)
- Sign in with your Kyma account via OAuth (Authorization Code + PKCE) —
  no manual API key management
- Credit balance display in Settings, with clear out-of-credits guidance
- Failed-dictation recovery: when transcription fails, your recording is
  saved locally and can be retried with one click — spoken words are never
  silently lost
- Recording survives microphone changes (AirPods disconnect mid-sentence
  no longer kills the dictation)
- Clipboard contents are restored after auto-paste, and dictated text is
  hidden from clipboard-history managers
- Custom dictionary for names and domain terms the model gets wrong
- Snippet triggers: say a word, get expanded text
- Onboarding wizard for first-launch permission setup
- Floating bar with waveform indicator during recording
- Transcription history with date grouping
- 4 transcription modes: Normal, Clean (remove fillers), Email (formal rewrite), Auto
- Mute music during dictation toggle
- Launch at login toggle
- Sound feedback themes: Deep Bass, Crystal, Minimal
- Auto-update via Sparkle
- haynoi.com landing page with download and update feed
