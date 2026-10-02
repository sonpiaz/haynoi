#!/bin/zsh
# Exit 0 only if NEW would read the keychain items OLD saved: both designated
# requirements are identical and neither is a cdhash (ad-hoc/self-signed, which
# changes with every build). Run after re-signing, before swapping the app.
#   scripts/same-signature.sh /Applications/Haynoi.app ./Haynoi.app
dr() { codesign -dr - "$1" 2>&1 | sed -n 's/^#* *designated => //p'; }
old=$(dr "$1"); new=$(dr "$2")
[[ -n $old && -n $new ]] || { echo "STOP: cannot read a signature requirement"; exit 2; }
[[ $new == cdhash* ]] && { echo "STOP: $2 is ad-hoc — the sign-in token would be lost (re-sign with Developer ID 448LBGWBYM)"; exit 1; }
[[ $old == cdhash* ]] && { echo "NOTE: the running app is ad-hoc; one sign-in will be needed after this install"; exit 0; }
[[ $old == "$new" ]] || { echo "STOP: requirement differs — the sign-in token would be lost"; echo " old: $old"; echo " new: $new"; exit 1; }
echo "OK: same designated requirement"
