#!/bin/bash
# Weekly (launchd, Mac mini): is any model Haynoi uses gone or retiring within 120 days?
# Quiet when all is well; one notify line to b-haynoi when not. Log: ~/Library/Logs/haynoi-model-retirements.log
cd "$(dirname "$0")/.." || exit 1
out=$(/usr/bin/python3 scripts/check-model-retirements.py --seen "$HOME/Library/Logs/haynoi-models-seen.txt" 2>&1); rc=$?
echo "$(date '+%F %T') rc=$rc"; echo "$out"
if [ $rc -ne 0 ]; then
  msg=$(echo "$out" | tail -1 | tr '\n' ' ' | cut -c1-300)
  "$HOME/cos/bin/notify" b-haynoi chan "[model-retirements job] $msg — run scripts/check-model-retirements.py in ~/haynoi (W37-1672)"
fi
exit $rc
