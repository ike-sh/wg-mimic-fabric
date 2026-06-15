#!/usr/bin/env bash

# Force-sync install.sh from GitHub (bypass CDN cache)

set -euo pipefail

REPO="${WMF_REPO:-ike-sh/wg-mimic-fabric}"

REF="${WMF_TAG:-main}"

[[ "$REF" == v* ]] || [[ "$REF" == "main" ]] || REF="v${REF}"

TS="$(date +%s)"

DEST="/usr/local/libexec/wg-mimic-fabric/install.sh"

tmp="$(mktemp)"

curl -fsSL -H "Accept: application/vnd.github.raw+json" \

    -o "$tmp" "https://api.github.com/repos/${REPO}/contents/install.sh?ref=${REF}" 2>/dev/null \

    || curl -fsSL -o "$tmp" "https://raw.githubusercontent.com/${REPO}/${REF}/install.sh?ts=${TS}"

install -d -m 755 "$(dirname "$DEST")"

install -m 755 "$tmp" "$DEST"

rm -f "$tmp"

echo "[OK] 已同步 $DEST"

