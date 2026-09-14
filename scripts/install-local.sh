#!/usr/bin/env bash
# Build a local Release of Haynoi and swap it into /Applications, so the copy
# you dictate with is the newest code within seconds of the build finishing.
#
#   ./scripts/install-local.sh              build → quit old → swap → relaunch
#   ./scripts/install-local.sh --rollback   put the previous copy back
#
# Same bundle id + same Developer ID as the shipped app, so macOS keeps the
# Accessibility, Input Monitoring and Microphone grants and the Keychain
# session. The running copy keeps working for the whole build; it is only down
# for the swap. Pattern from Mandeck: Developer ID for local builds (ad-hoc
# loses TCC), a versioned backup, and waiting for the old process to exit.
# The build number is BUILD_NUMBER.<commits since the release tag>, e.g. 32.4,
# which Sparkle reads as newer than the published 32 and older than 33.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source version.env

APP=/Applications/Haynoi.app
EXE="$APP/Contents/MacOS/Haynoi"
BUILT="$ROOT/build/Build/Products/Release/Haynoi.app"
STAGED="$ROOT/build/staged/Haynoi.app"
BACKUPS="$ROOT/build/backup"
mkdir -p "$BACKUPS"

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }

# PIDs whose executable is exactly the installed app — never a pattern match.
app_pids() { ps -axo pid=,comm= | awk -v exe="$EXE" '$2 == exe { print $1 }'; }

# Ask Haynoi to quit the way ⌘Q would, then wait until it has really exited.
# NSRunningApplication.terminate() needs no Automation consent; an AppleScript
# `quit` would stop and ask to let this terminal control Haynoi.
quit_running() {
  [[ -z "$(app_pids)" ]] && return 0
  swift -e 'import AppKit; for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.sonpiaz.haynoi") { _ = app.terminate() }' \
    >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    [[ -z "$(app_pids)" ]] && return 0
    sleep 0.2
  done
  echo "Haynoi is still running — choose Quit Haynoi in its menu bar icon; waiting…" >&2
  while [[ -n "$(app_pids)" ]]; do sleep 0.5; done
}

# Open the installed copy and wait for it; prints how long dictation was down.
launch_and_verify() {
  local started=$1
  open "$APP" || return 1
  for _ in $(seq 1 75); do
    if [[ -n "$(app_pids)" ]]; then
      echo "==> Running Haynoi $(plist "$APP" CFBundleShortVersionString) ($(plist "$APP" CFBundleVersion)) — down for $(( $(date +%s) - started ))s"
      return 0
    fi
    sleep 0.2
  done
  return 1
}

# Put a previous copy back at /Applications and start it. Loud if it can't.
restore() {
  local from=$1 started=$2
  rm -rf "$APP"
  if ! mv "$from" "$APP"; then
    echo "ROLLBACK FAILED — Haynoi is not installed. Run: mv \"$from\" \"$APP\" && open \"$APP\"" >&2
    exit 1
  fi
  launch_and_verify "$started" || echo "Restored $APP but it did not start — open it from Applications." >&2
}

if [[ "${1:-}" == "--rollback" ]]; then
  PREV=$(ls -td "$BACKUPS"/Haynoi-*.app 2>/dev/null | head -1 || true)
  [[ -n "$PREV" ]] || { echo "No backup in $BACKUPS" >&2; exit 1; }
  started=$(date +%s)
  quit_running
  if [[ -d "$APP" ]]; then
    CURRENT="$BACKUPS/rolled-back-$(date +%s).app"
    mv "$APP" "$CURRENT" || { echo "Could not move the current copy aside — relaunching it." >&2; open "$APP" || true; exit 1; }
  fi
  restore "$PREV" "$started"
  exit 0
fi

LOCAL_BUILD="$BUILD_NUMBER.$(git rev-list --count "v$MARKETING_VERSION..HEAD")"
LOG="$ROOT/build/install-local.log"
echo "==> Building Haynoi $MARKETING_VERSION ($LOCAL_BUILD) at $(git rev-parse --short HEAD) — the running copy keeps working meanwhile"
xcodegen generate --quiet
if ! xcodebuild -project Haynoi.xcodeproj -scheme Haynoi -configuration Release \
      -derivedDataPath build \
      MARKETING_VERSION="$MARKETING_VERSION" CURRENT_PROJECT_VERSION="$LOCAL_BUILD" \
      build > "$LOG" 2>&1; then
  tail -30 "$LOG"
  echo "Build failed — nothing was installed. Full log: $LOG" >&2
  exit 1
fi

codesign --verify --deep --strict "$BUILT"

# The new build must satisfy the installed copy's designated requirement —
# that is what TCC checks — or every permission has to be granted again.
BACKUP=""
if [[ -d "$APP" ]]; then
  REQ=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')
  if [[ -z "$REQ" ]] || ! codesign --verify -R "=$REQ" "$BUILT" 2>/dev/null; then
    echo "The new build does not satisfy the installed app's signing requirement — refusing to install (permissions would be lost)." >&2
    exit 1
  fi
  OLD_VERSION=$(plist "$APP" CFBundleShortVersionString 2>/dev/null || echo unknown)
  OLD_BUILD=$(plist "$APP" CFBundleVersion 2>/dev/null || echo unknown)
  BACKUP="$BACKUPS/Haynoi-$OLD_VERSION-$OLD_BUILD.app"
  rm -rf "$BACKUP"
fi

rm -rf "$(dirname "$STAGED")"
mkdir -p "$(dirname "$STAGED")"
ditto "$BUILT" "$STAGED"

# ---- From here on the user has no Haynoi until launch_and_verify succeeds.
started=$(date +%s)
quit_running
if [[ -n "$BACKUP" ]] && ! mv "$APP" "$BACKUP"; then
  echo "Could not move the old copy aside — relaunching it unchanged." >&2
  open "$APP" || true
  exit 1
fi

if ! mv "$STAGED" "$APP" || ! launch_and_verify "$started"; then
  echo "New build did not install or start — restoring the previous copy" >&2
  if [[ -n "$BACKUP" ]]; then
    restore "$BACKUP" "$started"
  fi
  exit 1
fi

# What is installed, for the next person who asks.
DIRTY=false
[[ -n "$(git status --porcelain --untracked-files=no)" ]] && DIRTY=true
cat > "$ROOT/build/installed.json" <<EOF
{"version":"$MARKETING_VERSION","build":"$LOCAL_BUILD","commit":"$(git rev-parse HEAD)","dirty":$DIRTY,"previous":"$BACKUP","installed_at":"$(date -u +%FT%TZ)"}
EOF

# Keep the three newest backups.
{ ls -td "$BACKUPS"/Haynoi-*.app 2>/dev/null || true; } | tail -n +4 | while read -r old; do rm -rf "$old"; done
