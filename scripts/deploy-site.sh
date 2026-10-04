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
#
# The PostHog key is not in the source: analytics.js carries a placeholder that
# this script fills from HAYNOI_POSTHOG_KEY (environment, or the repo's
# gitignored .env). No key, no deploy — a site that silently stops counting
# is worse than a deploy that refuses.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -z "${HAYNOI_POSTHOG_KEY:-}" && -f .env ]]; then
  HAYNOI_POSTHOG_KEY=$(sed -n 's/^HAYNOI_POSTHOG_KEY=//p' .env | tail -1)
fi
if [[ "${HAYNOI_POSTHOG_KEY:-}" != phc_* ]]; then
  echo "HAYNOI_POSTHOG_KEY is missing or not a PostHog project key; refusing to deploy." >&2
  exit 1
fi

# $OUT becomes the site root that gets deployed.
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# Guard 1 — skipped entirely when publishing a release, so a network blip on
# the appcast fetch can never block an intended release.
if [[ "${HAYNOI_RELEASE_APPCAST:-}" == "1" ]]; then
  echo "HAYNOI_RELEASE_APPCAST=1 — publishing appcast.xml as-is."
else
  LIVE="$OUT/.live-appcast.xml"
  curl -fsS https://haynoi.com/appcast.xml -o "$LIVE"
  if ! cmp -s "$LIVE" appcast.xml; then
    echo "appcast.xml differs from production; refusing to deploy." >&2
    echo "Publishing a release? Rerun with HAYNOI_RELEASE_APPCAST=1." >&2
    exit 1
  fi
  rm -f "$LIVE"
fi

# Guard 2 — stage only git-tracked files from site/ into the deploy root,
# then the appcast. site/functions/ is Pages Functions code, compiled by
# wrangler from --cwd site, not served as static files.
git ls-files -z site | while IFS= read -r -d '' f; do
  rel=${f#site/}
  [[ $rel == functions/* ]] && continue
  mkdir -p "$OUT/$(dirname "$rel")"
  cp "$f" "$OUT/$rel"
done
cp appcast.xml "$OUT/appcast.xml"

sed -i '' "s/__HAYNOI_POSTHOG_KEY__/${HAYNOI_POSTHOG_KEY}/" "$OUT/analytics.js"
if grep -qF "__HAYNOI_POSTHOG_KEY__" "$OUT/analytics.js"; then
  echo "analytics.js still carries the key placeholder; refusing to deploy." >&2
  exit 1
fi

wrangler pages deploy "$OUT" --cwd site --project-name=haynoi --branch=main --commit-dirty=true
