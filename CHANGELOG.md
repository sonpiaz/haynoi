# Changelog

All notable changes to Haynoi are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
