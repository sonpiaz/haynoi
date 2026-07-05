#!/bin/bash
# Deploy haynoi.com (Cloudflare Pages project "haynoi", not git-connected).
# Copies the release appcast into the site root first — the app's Sparkle
# feed URL is https://haynoi.com/appcast.xml, so every site deploy must
# carry the current appcast or auto-update breaks.
set -euo pipefail

cd "$(dirname "$0")/.."
cp appcast.xml site/appcast.xml
wrangler pages deploy site --project-name=haynoi --branch=main --commit-dirty=true
