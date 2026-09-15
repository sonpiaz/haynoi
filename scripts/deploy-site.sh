#!/bin/bash
# Deploy haynoi.com (Cloudflare Pages project "haynoi", not git-connected).
#
# A site deploy also publishes appcast.xml, the Sparkle feed every Haynoi
# install polls (https://haynoi.com/appcast.xml). Two guards keep a site change
# from breaking auto-update or shipping local junk:
#   1. The appcast.xml going out must match production, unless this deploy is
#      publishing a release (HAYNOI_RELEASE_APPCAST=1).
#   2. Only files tracked by git are uploaded, so untracked screenshots and
#      scratch pages in site/ never reach production.
set -euo pipefail

cd "$(dirname "$0")/.."

LIVE=$(mktemp)
curl -fsS https://haynoi.com/appcast.xml -o "$LIVE"
if ! cmp -s "$LIVE" appcast.xml && [[ "${HAYNOI_RELEASE_APPCAST:-}" != "1" ]]; then
  rm -f "$LIVE"
  echo "appcast.xml differs from production; refusing to deploy." >&2
  echo "Publishing a release? Rerun with HAYNOI_RELEASE_APPCAST=1." >&2
  exit 1
fi
rm -f "$LIVE"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
git ls-files -z site | while IFS= read -r -d '' f; do
  rel=${f#site/}
  mkdir -p "$OUT/$(dirname "$rel")"
  cp "$f" "$OUT/$rel"
done
cp appcast.xml "$OUT/appcast.xml"

wrangler pages deploy "$OUT" --project-name=haynoi --branch=main --commit-dirty=true
