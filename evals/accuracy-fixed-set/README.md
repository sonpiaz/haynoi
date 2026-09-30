# Fixed-set accuracy of the cloud path (W37-1574)

Sơn 18/09 20:36: "hình như Hãy Nói đã chỉnh sửa gì đúng không nên bắt chữ cực kỳ sai". Done-when on the ticket: re-measure on a fixed sentence set, compare with the previous build, conclude.

## Run
`~/cos/bin/chay-an ~/kyma-api/.env KYMA_API_KEY -- python3 run.py` — 12 lines of `sentences.txt` read by `say -v Linh`, sent as STTProvider.callTranscribe sends them (transcribe-quality, glossary + Normal prompt, json + logprobs), then the correction pass as STTProvider sends it (gemini-3.5-flash-lite, glossary + correctionPassPrompt) when a token is under −0.3.

## Previous build vs the one Sơn complained on
The installed build on 18/09 20:36 was 32.16 (installed 17/09 21:32); before it, 14/09's build `eb96ade`. `git diff eb96ade 022d4dc`: the cloud request (model, prompt, language, logprobs) and PersonalDictionary/Phonetics are **unchanged** — the same audio gives the same cloud transcript. The one change that alters text is the new on-device fallback (`7c136d3`): when the cloud call fails, Apple Speech's text is pasted, silently. That is the same mechanism as the 30/09 report (signed out → offline text).

## Measured 30/09 (current main; identical cloud request to 14/09 and 32.16)
| | raw STT | after correction pass |
|---|---|---|
| app prompt (glossary + mode) | WER 29.2 % (28.3 % on a second run) · terms 4/15 | **WER 22.6 % · terms 10/15** |
| mode prompt only (no dictionary) | WER 32.1 % · terms 3/15 | WER 30.2 % · terms 7/15 |
Pure-Vietnamese lines: 0 errors. Most errors are English terms the TTS voice says the Vietnamese way — a stand-in for Sơn's voice, not his voice.

## Conclusion
No regression on the cloud path across 0.3.x. The 18/09 "cực kỳ sai" matches offline text pasted after a cloud failure — not measurable from here (the MacBook's log). Fix: every offline fallback now says so, with the failure's own reason (0.3.13 only covered sign-out).
