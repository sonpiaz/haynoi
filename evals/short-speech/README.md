# Short replies — does the speech gate let "có" / "ok" through?

Report (29/09/2026 22:5x): "Nói ngắn ra thì nó không không nghe. Nó không có trả lời kết quả."

## Run
```
cd evals/short-speech
i=0; for w in "ok" "được" "cảm ơn" "đúng rồi" "gửi đi" "không" "xong rồi" "chào anh" "tiếp tục" "có"; do
  i=$((i+1)); say -v Linh -o w$i.wav --data-format=LEI16@16000 "$w"; done
afconvert -f WAVE -d LEI16@16000 -c 1 ../../Resources/Sounds/chime/start.wav tone.wav
python3 build.py                         # 80 buffers shaped like a real dictation
./gate.sh <git-rev | path/to/PipelineController.swift>   # compiles that hasSpeech, runs it on every buffer
```
Each buffer: 0.30 s pre-roll room noise (rms 0.0015) · start tone as the mic hears it at 0.30 s (off, or 0.05) ·
the word at 0.75 s, peak 0.30 / 0.06 / 0.03 / 0.015 (normal / quiet / soft / whisper) · 0.50 s tail. Words 0.26–0.76 s.

## Measured 29/09 (passes out of 20 per level; in brackets: without the tone in the mic, out of 10)
| level | 0.3.11 `f859415` | fix |
|---|---|---|
| normal | 20 (10) | 20 (10) |
| quiet | 20 (10) | 20 (10) |
| soft | 12 (2) | 19 (9) |
| whisper | 10 (0) | 12 (2) |

0.3.11 passed short soft words only when the tone was also in the mic — tone + word reached its 0.6 s.
Whisper peaks at ~3× the room floor; the gate cannot hear it and stays that way on purpose.

False positives on quiet negatives (average < 0.005, so the whole-buffer shortcut does not decide):
tone alone at 0.01/0.02/0.03, on time and 200 ms late; a 0.2 s thump; clicks; a fan; a quiet room —
0/10 pass with the fix (parameter sweep in the commit that introduced this folder).
