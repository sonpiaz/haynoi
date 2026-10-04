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

## "Fast but wrong" is the offline recognizer, not the hint (2026-09-30)

0.3.12 pasted "đếch" for "deck" and "Asian" for "agent" with both in the
dictionary. The first guess blamed the newest hint change; the app's own
Phonetics showed none of the seven words had ever been hinted. Signed out,
Haynoi skipped the cloud and pasted the offline recognizer's text with no
notice — and a keychain read that fails because the build is signed
differently looks exactly like signed out. Measure a guess against the code
before changing the code; never degrade silently.

cơ chế: `Tests/SignedOutFallbackTests.swift`, `Tests/MisheardPairsTests.swift`; keychain failures now log their OSStatus.

## Retro before away-plan wave 2 (2026-09-30)

- Khác dự tính: lỗi "0.3.12 sai chính tả" bị đoán là do commit mới nhất (8c64eb2); đo bằng chính Phonetics của app thì 0/7 cặp từng qua bộ gợi ý — gốc nghi là app mất token rồi lặng lẽ dùng nhận giọng offline.
- Học được: kiểm giả thuyết bằng code thật (harness `swiftc` vài phút) trước khi sửa code; và mọi đường "giảm chất lượng" phải lên tiếng, không được im.
- Áp ngay: audit và dọn AX hôm nay đều đo trước/sau bằng số, và mỗi fallback mới phải có log hoặc thông báo.

## Retro before day wave 2 (2026-10-01)

- Khác dự tính: brief ngày giao W37-1796 audit + pull list W37-1406/1391/1672/1574, nhưng cả năm vé đã merge local từ 30/09 (Grok ĐẠT đúng head) — plan viết từ board, board chưa thấy main local chưa push.
- Học được: trước khi nhận vé từ plan, đo `git log --grep` trên main local; vé "xong local, chưa push" nhìn từ board vẫn như còn mở.
- Áp ngay: chỉ làm phần còn thật (W37-1424 latency, đo từng chặng bằng `say` + script trong `evals/`), báo runner là pull list đã hết.

## Optional polish must not borrow the required step's budget (2026-10-01)

The logprob correction pass is optional, but it reused the email rewrite's
policy: 15 s idle timeout, three tries, 2/4/8 s sleeps on 429. A busy upstream
held text that was already transcribed for 2–17 s (W37-1424). Give every optional
network step its own total budget (`timeoutIntervalForResource`, not the idle
`timeoutInterval`) and one try. Never sleep after the last attempt of a retry loop.

cơ chế: `Tests/CorrectionBudgetTests.swift`, `evals/latency/`.

## The sign-in token survives an install only if the signature does (2026-10-01)

The token is a legacy keychain item trusted by the saving app's designated
requirement and partition (`teamid:` for Developer ID, `cdhash:` for ad-hoc).
An ad-hoc or other-team build does not fail the read — it blocks on a keychain
password dialog (`kSecUseAuthenticationUIFail` is ignored for legacy items), and
a cancel looks like "signed out". No app-side change keeps the token without
opening it to other apps. Every install compares requirements first.

cơ chế: `scripts/same-signature.sh` (in INSTALL-MACBOOK.md step 3; the MacBook job must call it).

## Retro before night batch (2026-10-01)

- Khác dự tính: lỗi "mất đăng nhập sau mỗi lần cài" không sửa được trong app — nó nằm ở chữ ký của bản cài; và hộp thoại keychain bật lên dù đã đặt `kSecUseAuthenticationUIFail` (probe phải bị dừng tay).
- Học được: thử keychain trên máy không người phải chạy có timeout, vì legacy item không bao giờ trả lỗi thay cho hộp thoại.
- Áp ngay: lô Kit (W37-940/945/946/948) làm trong bản clone local của `affitor-app-kit` (code không nằm trong `~/haynoi`); đo "đã làm chưa" trên nhánh trước khi viết dòng nào.

## Notify "merged" only after reading the branch back (2026-10-02)

W37-945: `git fetch . 32deadc:feat/…` failed (a short sha is not a ref), the
chained notify still ran and reported "merged". Corrected minutes later. Merge,
then `git log -1 <branch>`, then notify — never in one line that keeps going
past a failed step.
## Retro · 02/10 Pro coming soon (start of batch)
- Different from plan: START-HERE said 34d5ed5 was waiting to deploy; cos-board says it went live at 08:3x (byte-diffed `/` against 34d5ed5: same).
- Learned: "waiting to deploy" rows go stale within hours; diff live before choosing a base.
- Applied now: base = 34d5ed5 (live); every Pro sentence is checked against one fact: Pro is not on sale.

## PostHog ignores chrome-headless-shell (2026-10-02)
`posthog._is_bot()` is true in Playwright's headless shell even with a normal UA, so no event leaves the page. Verify live events with the full Chromium build and `posthog.on('eventCaptured', …)`.

## Retro · 03/10 night wave 3 H1 (start of batch)
- Different from plan: 02/10 site work (Pro coming soon, CTA #5) needed two Grok runs on r2 (900s timeout cut the findings).
- Learned: give Grok ≥2400s and ask for ≤12 lines of findings; PostHog only verifies in full Chromium.
- Applied now: measure each ticket against the repo before touching it; fix files only, never rewrite history.

## Retro · 03/10 day shift (start)
- Different from plan: night H1 found most open tickets already done or waiting on Sơn (spec 19/09, Cloudflare); only 2 small fixes were safe.
- Learned: on the mini, XCTest needs `-scheme HaynoiTests` + ad-hoc flags; the `Haynoi` scheme has no test action.
- Applied now: before picking tickets, read the last comments first; most "open" haynoi tickets are parked on Sơn.

## Retro · 03→04/10 night wave 1 H1 (start)
- Different from plan: the plan asks to build W37-940 + W37-945, but both are already done and ĐẠT (Grok + Claude) on kit `40c9457`, waiting for deploy since 02/10.
- Learned: night plans are written from board titles; the board still shows these as backlog because nobody with rights closed them.
- Applied now: measure first, re-run the kit tests on 40c9457, report "already done" with evidence instead of rebuilding.

## Retro · 04/10 day shift (start)
- Different from plan: the night H1 kit tickets were already done; H2 soak needed a re-signed copy because builds on the mini are ad-hoc and Sparkle carries another Team ID.
- Learned: to run any `~/haynoi-builds` app on the mini, ad-hoc `--deep` re-sign a copy first; never touch the build folder.
- Applied now: measure each PR (state, head, base, conflicts) before asking for review.
