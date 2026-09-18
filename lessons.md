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
