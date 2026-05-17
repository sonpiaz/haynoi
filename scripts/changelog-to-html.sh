#!/usr/bin/env bash
# Extract the section for a given version from CHANGELOG.md and convert to HTML.
# Used by make_appcast.sh to populate Sparkle release notes.
#
# Usage: changelog-to-html.sh 0.1.0
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:?"Usage: $0 <version>"}
CHANGELOG="$ROOT/CHANGELOG.md"

if [[ ! -f "$CHANGELOG" ]]; then
  echo "<p>No release notes available.</p>"
  exit 0
fi

# Extract section between "## [VERSION]" and next "## [" header.
SECTION=$(awk -v ver="$VERSION" '
  $0 ~ "^## \\[" ver "\\]" { found=1; next }
  found && /^## \[/ { exit }
  found { print }
' "$CHANGELOG")

if [[ -z "$SECTION" ]]; then
  echo "<p>No release notes for version $VERSION.</p>"
  exit 0
fi

# Minimal Markdown → HTML conversion. Sparkle accepts HTML in <description>.
# We handle: h3 headings, lists, paragraphs, inline code, bold, links.
echo "<h2>Haynoi $VERSION</h2>"
echo "$SECTION" | awk '
  /^### / { sub(/^### /, ""); print "<h3>" $0 "</h3>"; next }
  /^- / {
    if (!in_list) { print "<ul>"; in_list=1 }
    sub(/^- /, "")
    print "<li>" $0 "</li>"
    next
  }
  /^$/ {
    if (in_list) { print "</ul>"; in_list=0 }
    print ""
    next
  }
  {
    if (in_list) { print "</ul>"; in_list=0 }
    print "<p>" $0 "</p>"
  }
  END { if (in_list) print "</ul>" }
' | sed -E 's|`([^`]+)`|<code>\1</code>|g; s|\*\*([^*]+)\*\*|<strong>\1</strong>|g'

echo "<p><a href=\"https://github.com/sonpiaz/haynoi/blob/main/CHANGELOG.md\">View full changelog</a></p>"
