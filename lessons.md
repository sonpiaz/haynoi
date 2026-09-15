# Haynoi lessons

## Email rewrite must not drop the transcript (2026-09-15)

The Email (and Auto→Email) path ran STT then `try await rewriteWithKyma`. HTTP
errors already returned the raw text; **timeout, task cancel, and 401 threw**,
so `transcribeTracked` failed and `PipelineController` discarded the cloud STT.
The user lost the words they just spoke (unless on-device had a fallback).

The correction pass already used `try?`. Email rewrite must do the same:
`keepTranscriptIfRewriteFails` — on any throw, paste the original transcript.
401 may still sign the user out; the dictation still inserts.
