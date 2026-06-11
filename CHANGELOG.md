# Changelog

All notable changes to Haynoi are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
