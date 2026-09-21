# Haynoi lessons

## Dev and tests must not write the live dictionary (2026-09-17)

The live file is `~/Library/Application Support/Haynoi/dictionary.json`.
On 2026-09-17 18:29 it went from 30 manual entries to empty (`[]`, 4 bytes)
while Debug builds were being installed. Tests already used a temp folder
(wipe of 2026-09-01); Debug still shared the production folder.

Debug (`com.sonpiaz.haynoi.dev`) writes `Application Support/Haynoi-Dev/`.
Tests stay in a per-PID temp folder. `persist()` refuses the production
path unless the bundle id is exactly `com.sonpiaz.haynoi`. Restore from
`.internal/backups/` and `uchg`-lock until the user relaunches.

## Email rewrite must not drop the transcript (2026-09-15)

The Email (and Auto→Email) path ran STT then `try await rewriteWithKyma`. HTTP
errors already returned the raw text; **timeout, task cancel, and 401 threw**,
so `transcribeTracked` failed and `PipelineController` discarded the cloud STT.
The user lost the words they just spoke (unless on-device had a fallback).

The correction pass already used `try?`. Email rewrite must do the same:
`keepTranscriptIfRewriteFails` — on any throw, paste the original transcript.
401 may still sign the user out; the dictation still inserts.

## Never-die must not cancel Quality at 2.5s (2026-09-15)

The 2.5s deadline is “don’t leave him empty-handed,” not “Quality is dead.”
`cloudTask.cancel()` at the deadline inserted incomplete Apple Speech and killed
the better transcript. Keep the cloud request running; paste Apple at 2.5s;
`replaceSpan` (no fallback insert) when Quality arrives if the span is still
intact and the user did not switch apps. On cloud error, keep Apple.

## Running the tests must not run the app on someone's machine (2026-09-20)

The suite uses the app as its test host, so every `xcodebuild test` launched a
debug Hãy Nói: a second menu bar icon for a few seconds, the updater, and the
global ⌥ push-to-talk chord — 22 times in one hour, on the machine its owner was
working on. From the outside it looked like the app switching itself on and off.

Two rules:

- A test run may not start anything that touches the machine. `RunMode` answers
  it once; the launch path, the menu bar scene and the updater read it.
- Keep two questions apart. *Was I started by a test runner?* is a fact and has
  to be answered honestly in every configuration, because the code deciding
  where the owner's files live reads it. *Should I refuse to start the runtime?*
  is a policy, and a Release build always answers no — a shipped app must never
  disable itself over an inherited environment variable.

Still open, same family: `history.json` is a hardcoded path with no bundle-id and
no test awareness, so a debug build reads and writes the owner's real history —
exactly the shape of the dictionary loss on 2026-09-17, which `dictionary.json`
now guards against on both counts.

cơ chế: `Tests/TestHostTests.swift`.

## A scripted multi-file edit that throws leaves half the change (2026-09-20)

A patch script wrote `RunMode.swift` and the tests, then hit an assertion before
it reached `HaynoiApp.swift`. `git add -A` staged what had changed, the suite
went green — it only exercised `RunMode` on its own — and the commit message,
`lessons.md` and a test all announced a guarantee the code did not have: the
launch path still read the function whose `#if DEBUG` had just been moved away,
so a shipped build could have started invisible.

Before committing a scripted edit: `git show --stat` / `git diff --stat` and read
the list of files. If the script raised anything, assume nothing landed. And when
two functions answer the same thing in Debug, no behaviour test can tell which
one production calls — name them apart and check the source.

cơ chế: `Tests/TestHostTests.swift` — `testTheLaunchPathAsksThePolicyAndNeverTheFact`.
