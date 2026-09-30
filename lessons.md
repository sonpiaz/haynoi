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

Closed 2026-09-29 (W37-1406): `history.json`, `insights.json`, `failed/` and the
paste counters now resolve their folder through `PersonalDictionary.supportDirectory()`,
the one place that knows Release → `Haynoi`, Debug → `Haynoi-Dev`, tests → temp.
Before, a debug build read and wrote the owner's real history, and a test run
created `Haynoi` and `Haynoi-Dev` in the Application Support of whatever machine
ran it (measured on the Mac mini). A lookup must not create the folder it names.

cơ chế: `Tests/TestHostTests.swift`, `Tests/OwnerFilesIsolationTests.swift` (no source but `PersonalDictionary.swift` may resolve Application Support).

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

## A silence gate must look for a voice, not at the average (2026-09-22)

The gate before transcription compared the RMS of the whole recording with a
fixed 0.005. On 2026-09-22 23:00–23:41 it dropped seven real dictations as
"No speech detected": a quiet voice at night with pauses between sentences
averages under that, even when every spoken frame is well above the room. The
audio was discarded before the network, so there was no request, no saved
recording to retry, and the only trace was the error tone.

Judge 30 ms frames against the recording's own noise floor, and keep the old
average as a pass so nothing that used to go through stops going through. The
start tone reaches the mic, so the minimum stretch of voice must be longer
than the tone (0.42 s → 0.6 s), and only unbroken 150 ms stretches count, so
the tone plus a few clicks does not add up to a voice.

How it was found without reading a word: the error tone has its own length in
the unified log (0.75 s vs 0.66 start / 0.66 stop), no request followed, the
engine stayed warm (rules out the mic watchdog), and `failed/` got nothing
(rules out a transcription failure).

cơ chế: `Tests/SpeechGateTests.swift`.

## Retro before night wave 3 (2026-09-30)

- Khác dự tính: bản 0.3.11 chỉ nằm trên MacBook nên hai fix (đuôi 500 ms, gate câu ngắn) phải chờ nhánh `macbook-0.3.11`; gate câu ngắn cần 3 vòng Grok vì mỗi cách loại start tone (theo vị trí, cửa sổ đệm) đều nuốt một kiểu câu trả lời thật.
- Học được: một bộ lọc dựa vào *vị trí* hay *cửa sổ rộng* sẽ gán nhầm thứ nằm cạnh; so khớp trên đúng mẫu của đoạn đó. Và số đo phải chạy lại từ script trong repo (`evals/`), không từ file nháp.
- Áp ngay: mỗi fix âm thanh có một thư mục `evals/<tên>/` sinh audio + chạy lại được trước/sau; không build Xcode khi máy đang bận — logic thuần kiểm bằng `swiftc` harness, XCTest đầy đủ chạy khi máy rảnh.
