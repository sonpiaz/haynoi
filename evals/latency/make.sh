#!/bin/zsh
# Synthetic speech only (macOS voice Linh) — never a recording of a person.
cd "${0:A:h}"
i=0
while IFS= read -r l; do
  i=$((i+1))
  /usr/bin/say -v Linh -o l$i.wav --data-format=LEI16@16000 "$l"
  afconvert -f m4af -d aac -b 24000 l$i.wav l$i.m4a   # same codec/bitrate as STTProvider.createM4A
done < sentences.txt
for f in l*.wav; do printf '%s %.1fs %s B (m4a %s B)\n' $f $(afinfo $f | awk '/estimated duration/{print $3}') $(stat -f%z $f) $(stat -f%z ${f%.wav}.m4a); done
