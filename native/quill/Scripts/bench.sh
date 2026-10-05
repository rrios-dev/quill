#!/bin/bash
#
# Builds quill-bench, signs it with the Developer ID certificate and runs it (BENCH §3).
#
# Signed so the bench's Keychain items — its own service, quill.bench — are partitioned by
# team id and rebuilds are not re-prompted (ARCHITECTURE §3.5, §4.2). Never ad hoc.
#
#   Scripts/bench.sh run --profiles spelling --models apple.on-device:system --repeat 3 --label tuning-1
#   Scripts/bench.sh keys set openrouter
#
set -euo pipefail

QUILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$QUILL"
log() { echo "$@" >&2; }

swift build -c release --product quill-bench >&2
BIN="$(swift build -c release --show-bin-path)/quill-bench"

IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
# By its SHA-1, not its name: on macOS 27 a name with a non-ASCII letter ("Ríos") reaches
# codesign mis-encoded and matches no identity. The hash is plain ASCII.
IDENTITY="${CODESIGN_IDENTITY:-$(sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Developer ID Application: [^"]*".*/\1/p' <<<"$IDENTITIES" | head -1)}"
if [ -z "$IDENTITY" ]; then
  case "$IDENTITIES" in *"Ambar Local Signing"*) IDENTITY="Ambar Local Signing" ;; esac
fi
if [ -z "$IDENTITY" ]; then
  log "✗ No Developer ID certificate (or the local fallback) to sign quill-bench with."
  exit 1
fi
codesign --force --options runtime --timestamp=none --identifier dev.rrios.quill.bench --sign "$IDENTITY" "$BIN" >&2

exec "$BIN" "$@" --data "$QUILL/tools/QuillBench/data"
