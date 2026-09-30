# Release tail — does the last word survive the key release?

Report (29/09/2026): "nó thường thiếu cái chữ cái cuối cùng". 4 of Son's last 8
dictations ended one word short in history ("…vào buổi", "…cho các xe").

## Run
```
cd evals/release-tail
i=0; while IFS= read -r l; do i=$((i+1)); say -v Linh -o s$i.wav --data-format=LEI16@16000 "$l"; done < sentences.txt
python3 cut.py            # s*-full / -atend / -early(150 ms) and cut300 / cut450 variants
~/cos/bin/chay-an ~/kyma-api/.env KYMA_API_KEY -- python3 stt.py transcribe-quality
```
`stt.py` reads `KYMA_API_KEY` from the .env itself (chay-an only masks output). Needs a Kyma key.

## Correct behaviour
The pipeline records `PipelineController.tailMs` (500 ms) after release, so audio
reaching STT ends ≥ 450 ms after the release point; every sentence keeps its last word.

## Measured 29/09 (transcribe-quality → gpt-4o-mini-transcribe, TTS voice Linh)
| cut before end of speech | last word kept |
|---|---|
| +500 ms silence (full) | 6/6 |
| 0 ms | 5/6 (s5 came back as Chinese) |
| 150 ms | 3/6 kept, 2 mangled ("model"→"môn", "lỗi"→"lộn"), 1 Chinese |
| 300 ms | 2/6 |
| 450 ms | 0/6 — "…vào buổi", "…cho các", "…cái này", "…ra mắt sản": Son's symptom |

whisper-v3-turbo kept the last word at 150 ms in 6/6; the default is Quality.

## After the fix (same audio, release point as above, 500 ms recorded after it)
| release before end of speech | last word kept, before → after |
|---|---|
| 300 ms | 2/6 → 6/6 |
| 450 ms | 0/6 → 5/6 (s5 came back as Chinese, as it also does uncut with no trailing silence — a language-detection miss, not the tail) |
