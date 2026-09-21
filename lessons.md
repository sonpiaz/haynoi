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
the list of files. If the script raised anything, assume you do not know what
landed — read the file list, do not re-run blindly, or the parts that did land get
applied twice. And when two functions answer the same thing in Debug, no behaviour
test can tell which one production calls — name them apart and check the source.

cơ chế: `Tests/TestHostTests.swift` —
`testOnlyTheDataLayerAsksTheFactAndThePolicyHasFourCallers` (phần đặt tên và chỗ
gọi); phần đọc `--stat` trước khi commit: **chưa có cơ chế**, mới là thói quen.

## A gate written against one shape only catches that shape (2026-09-21)

gemini-2.5-flash stops answering on 2026-10-20. Nothing here fails loudly when
it does: the email rewrite keeps the raw transcript and the correction pass is
wrapped in `try?`, so the deadline would have arrived as a feature going quiet.

The guard added with the fix scanned lines containing `"model"`, and a mutation
proved it — the author's own mutation used a literal on that same line, which is
the shape the check was written against. A review moved the name into a private
constant and the suite stayed green while the app still asked for a dead model.
**Mutating your own guard with the shape you had in mind proves nothing.** Hand
it to someone who will try a shape you did not.

The check now looks for the name on any non-comment line. Two things it still
cannot see, written down so nobody reads it as more than it is: a name assembled
at runtime, and anything behind a server-side alias — `transcribe-quality` is
resolved by the server, and the model behind it retires 2027-02-26. Those need
the catalog, which publishes `retires_on`, not the source.

cơ chế: `Tests/RetiredModelTests.swift`; phần alias: **W37-1672** (job đọc
`retires_on` từ `/v1/models`), chưa làm. Cùng vòng duyệt còn mở **W37-1673**:
gợi ý phát âm sửa "Hà Nội" thành "Haynoi" — sửa sai một từ người dùng nói đúng.
