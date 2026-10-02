# Haynoi: Changelog

Source: https://haynoi.com/changelog/

- [How it works](https://haynoi.com/#how)
- [Features](https://haynoi.com/#features)
- [Download](https://haynoi.com/thanks/)

Changelog

# A ledger of the *ledger*.

## 0.3.10 — September 1, 2026

*Honest errors, scored learning.*

- When our servers have a problem, Haynoi now says so — instead of telling you that you're out of words, or signing you out.
- Every learned word now carries a scoreboard: how many times it was applied and how often you let it stand — visible per word and summed up in the Dictionary tab.

## 0.3.9 — August 29, 2026

*A same-day fix.*

- Fixed a crash when reopening the main window after closing it — a long-standing window memory bug that 0.3.8 surfaced.

## 0.3.8 — August 29, 2026

*It gets out of your way — and learns you.*

- Other audio steps aside while you dictate: music and video pause and resume on their own; a live call or stream is dipped in volume instead — decided from what your Mac is actually playing, never a blind guess.
- Your corrections now teach the AI cleanup pass. Fixes you've confirmed — like a name that sounds identical to a common word — are repaired automatically next time.
- Haynoi notices when the transcriber wasn't sure of a word and gives that one dictation an extra pass through your personal fixes, matched by sound. Confident dictations skip it, so nothing gets slower.
- You're in charge of what Haynoi learns: a master switch, a learned-words counter, and a one-tap "Forget all" in the Dictionary tab. Words you added yourself are always kept.
- Fixed: scrolling froze for a moment right after every dictation, and "Pause audio while dictating" never ran on a fresh install.

## 0.3.7 — July 5, 2026

*Pro is live.*

- Haynoi Pro: unlimited dictation, all 4 modes, priority transcription — $14.99/month or $125.88/year. Upgrade in Settings → Plans & Billing; checkout runs through Stripe in your browser and the app unlocks within seconds.
- Fixed usage analytics silently not reporting (counts and timings only — never your words).

## 0.3.6 — July 4, 2026

*The relaunch.*

- New sign-in: continue with Google — one click, no passwords. Accounts are now Haynoi's own. Existing users will be asked to sign in again once after updating.
- Your personal dictionary now learns from corrections. Say "fix that", edit a dictation in place, or re-dictate — Haynoi notices the fix and gets the term right next time. Everything stays on your Mac.
- Free tier is 5,000 words per week, resetting every Monday.
- Obsidian Instrument relaunch: light-first redesign and the new "ń" tone-mark logo, now bigger in the Dock and shown throughout the app.
- Dictation runs through Haynoi's own backend. Anonymous usage analytics (counts and timings only — never your words) with an opt-out toggle in Settings.

## 0.3.5 — June 12, 2026

*A shorter glow.*

- The microphone releases about 10 seconds after you finish dictating (it was a minute), so the macOS orange "mic in use" dot doesn't linger. Back-to-back dictations stay instant.

## 0.3.4 — June 12, 2026

*Tell me what's wrong.*

- New “Test connection” button in Settings → Account — checks whether your dictation can reach our servers on each route and explains, in plain language, what's blocking it (network, sign-in, or credits). Free; it doesn't transcribe.

## 0.3.3 — June 12, 2026

*The real fix for slow networks.*

- Recordings now upload in a compressed format about 5× smaller, so dictation reaches the server even on congested networks where the larger upload used to stall. This is the true cause behind the "Something went wrong" errors some users saw after speaking — especially in Vietnam.

## 0.3.2 — June 12, 2026

*A lighter touch on the network.*

- The route check now pings a 93-byte health endpoint instead of downloading the full model list — checking your network routes uses almost no data.

## 0.3.1 — June 12, 2026

*Routes that follow you around.*

- Haynoi re-checks its network routes whenever your connection changes — new Wi-Fi, VPN on or off, waking the laptop somewhere else — not just at launch.

## 0.3.0 — June 12, 2026

*Three roads, raced — your network picks the winner.*

- Haynoi probes its API routes at launch and dictates over the fastest one that works from your network. A stalled route triggers a parallel race after 4 seconds, and the winner is remembered — a bad network costs seconds once, not on every sentence.

## 0.2.7 — June 12, 2026

*For everyone who kept seeing “Something went wrong”.*

- Dictation now works on networks where the audio upload stalls (reported from Vietnam) — Haynoi automatically retries through an alternate route.

## 0.2.6 — June 12, 2026

*Buttons that do what they say.*

- The Settings gear and Sign in buttons in the menu bar panel work again — they had been calling a retired macOS hook that silently did nothing.

## 0.2.5 — June 12, 2026

*Out of the Dock, into the menu bar.*

- Haynoi is now a menu-bar app — no Dock icon while you work; it appears only when the main window is open.
- The menu bar panel lists your 5 most recent dictations with a copy button on each row.

## 0.2.4 — June 12, 2026

*The panel that was hiding in 10 pixels.*

- Clicking the menu bar icon shows the panel again — it had been opening collapsed to a 10-pixel sliver, which looked like nothing at all.
- Insights, tidied: one headline, one unified row of stat cards (words · pace · streaks), the heatmap, and where your words go. Duplicate app rows merged.

## 0.2.3 — June 12, 2026

*Smooth again.*

- Fixed the sluggishness after dictating — an internal signal was re-rendering the UI ~47×/second for a minute after each dictation. Scrolling and the menu bar panel are smooth again.
- The copy button is back on every history row — always visible, rows never shift. Recent is gone; it duplicated History.

## 0.2.2 — June 12, 2026

*History that holds still.*

- History rows no longer shift on hover and the language badge is gone — Copy and Delete moved to the right-click menu.

## 0.2.1 — June 12, 2026

*Instant to the touch, cosmic to the eye, quieter to the ear.*

- The press registers almost immediately — the start chime now lands about a tenth of a second after your finger does.
- The indicator moved to the **top-center** of the screen, in a dark cosmic capsule with an aurora halo that swells only with your voice.
- Exactly two tones per dictation: press and release. The “N words” chip appears silently; no more violet dot while transcribing.

## 0.2.0 — June 12, 2026

*A waveform that tells the truth, and a kinder pair of bells.*

- New recording indicator: **Trail** — a scrolling waveform where your last second of speech stays visible. Silence is a flat line; the trail only moves with your voice.
- New default sound theme: **Chime** — a gentle bell pair on start and stop. Previous themes remain in Settings.
- When your text lands, a small **“N words”** chip pops up with a subtle chime — both can be turned off in Settings → Sounds.

## 0.1.9 — June 12, 2026

*Dictation now starts the instant you press the key.*

- The microphone stays warm between dictations — no more cold-start wait when you press the key, even on Bluetooth headsets.
- A 300ms pre-roll is captured before recording officially begins, so your first word is never clipped again.
- The start tone now plays exactly when the mic is truly live — when you hear it, you can speak.
- The recording waveform follows your real voice: silent means still, speaking means moving.
- Pasting is ~250ms faster when dictating into the app you're already in.
- Hotkey hints corrected everywhere: hold left Option (⌥) alone — there was never a Space involved.

## 0.1.0 — June 11, 2026

*The first public release.*

- Push-to-talk dictation: hold ⌥ (or ⌘ / ⌃ / fn), speak, release — polished text lands in whatever app you're using.
- Vietnamese-first transcription that keeps mixed English intact, with a language preference: auto-detect, Tiếng Việt, or English.
- Your words are never lost — failed transcriptions save the recording locally and retry with one click.
- Recording survives real life: AirPods disconnecting mid-sentence, permission hiccups, and flaky Wi-Fi all degrade gracefully.
- Auto-paste with clipboard restore afterwards, and dictated text stays hidden from clipboard managers.
- A living status orb: recording, transcribing, success, and error each have their own state.
- Custom dictionary, spoken snippets, smart modes (Normal, Clean, Email, Auto), and music auto-pause while you dictate.
- Credit balance in Settings with clear out-of-credits guidance — pay as you go through Kyma, no subscription.
- Quality and Fast transcription tiers, searchable local history, sound themes, and silent auto-updates via Sparkle.
- The Mercury interface: a private ledger of everything you've said, on paper and ink, with one aurora hairline.

[Download 0.1.0 from GitHub Releases](https://github.com/sonpiaz/haynoi/releases/tag/v0.1.0)

© 2026 Affitor LLC. All rights reserved.

- [GitHub](https://github.com/sonpiaz/haynoi)
- [Download](https://haynoi.com/thanks/)
- [Powered by Kyma](https://kymaapi.com)
