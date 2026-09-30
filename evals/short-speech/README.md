# Short replies — does the speech gate let "có" / "ok" through?

Report (29/09/2026 22:5x): "Nói ngắn ra thì nó không không nghe. Nó không có trả lời kết quả."

## Run
```
cd evals/short-speech
i=0; for w in "ok" "được" "cảm ơn" "đúng rồi" "gửi đi" "không" "xong rồi" "chào anh" "tiếp tục" "có"; do
  i=$((i+1)); say -v Linh -o w$i.wav --data-format=LEI16@16000 "$w"; done
afconvert -f WAVE -d LEI16@16000 -c 1 ../../Resources/Sounds/chime/start.wav tone.wav
python3 build.py                                          # 174 buffers (see the header of build.py)
./gate.sh <git-rev | path/to/PipelineController.swift>    # compiles that gate, runs it on every buffer
```
The gate gets the chime as its tone template in every run (sound on), including when the tone is not in
the mic — headphones, the harder case.

## Measured 29/09 — passes (words 0.26–0.76 s; 10 words × tone on/off × start 0.55/0.75 s = 40 per level)
| level | 0.3.11 `f859415` | fix | tone not in mic | reply starting at 0.55 s |
|---|---|---|---|---|
| normal | 40 | 40 | 20 → 20 | 20 → 20 |
| quiet | 40 | 40 | 20 → 20 | 20 → 20 |
| soft | 24 | **37** | 4 → 17 | 12 → 18 |
| whisper | 20 | 24 | 0 → 4 | 10 → 12 |
| negatives (14) wrongly passed | 1 | 1 | | |

The one negative that passes both is `neg-clicks`: its whole-buffer average is 0.0065, above the 0.005
shortcut that predates 0.3.11. Tone alone (3 levels × on time / 200 ms / 450 ms late), a burst then the
tone, a thump, a fan and a quiet room are all rejected.
Whisper peaks at ~3× the room floor; below that the gate does not hear it, on purpose.

Known limit: a short reply said entirely over the tone (a 0.3 s reply starting 0.30–0.55 s, tone at
0.30 s, both in the mic) merges with it and is dropped — as in 0.3.11. Before or after the tone passes
(sweep 0.00–1.00 s in 0.05 steps: drops only at 0.30–0.55).

## Also seen (not the gate)
Sent to transcribe-quality, short words often come back in the wrong language ("ok" → "어?",
"tiếp tục" → "계속", "có" → "거") even with `language=vi`. Tracked separately.
