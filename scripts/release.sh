#!/usr/bin/env bash
# Orchestrate the full release pipeline locally.
# Used for manual releases; CI runs the same scripts inline (see .github/workflows/release.yml).
#
# Usage: ./scripts/release.sh [version]
#   If version omitted, uses MARKETING_VERSION from version.env.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source "$ROOT/version.env"

VERSION=${1:-$MARKETING_VERSION}
if [[ "$VERSION" != "$MARKETING_VERSION" ]]; then
  echo "Tip: edit version.env first if you want to bump permanently."
fi

echo "==> Building universal Haynoi.app v$VERSION"
ARCHES="arm64 x86_64" "$ROOT/scripts/package_app.sh" release

echo "==> Signing + notarizing"
"$ROOT/scripts/sign-and-notarize.sh"

echo "==> Generating appcast"
"$ROOT/scripts/make_appcast.sh" "Haynoi-${VERSION}-universal.zip"

cat <<EOF
==> Release artifacts ready:
    Haynoi-${VERSION}-universal.zip
    Haynoi-${VERSION}-universal.dSYM.zip
    appcast.xml (updated)

Next steps:
  1. Commit appcast.xml + push
  2. Create GitHub release for tag v${VERSION}
  3. Upload zip + dSYM as release assets

  gh release create v${VERSION} \\
    Haynoi-${VERSION}-universal.zip \\
    Haynoi-${VERSION}-universal.dSYM.zip \\
    --notes-from-tag
EOF
