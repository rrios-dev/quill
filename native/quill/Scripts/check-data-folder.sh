#!/bin/bash
#
# The data folder holds only what PRODUCT §7 lists (PLAN P5-T5): settings, cached model
# lists, profiles with their versions and samples, files set aside as corrupt, the
# bench's folders when the bench was used, and — in development builds — probe rows.
# Anything else fails, by path; contents are never printed.
#
#   Scripts/check-data-folder.sh <data folder>
#
set -euo pipefail
DIR="${1:?usage: check-data-folder.sh <data folder>}"
[ -d "$DIR" ] || { echo "✗ no data folder at $DIR" >&2; exit 1; }

UUID='[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'
ALLOWED="^(settings\\.json|settings\\.corrupt-[0-9TZ-]+\\.json|cache/models-[a-z0-9.-]+\\.json|cache/models-[a-z0-9.-]+\\.corrupt-[0-9TZ-]+\\.json|profiles/$UUID/(current|samples)\\.json|profiles/$UUID/(current|samples)\\.corrupt-[0-9TZ-]+\\.json|profiles/$UUID/versions/[0-9]+\\.json|profiles/$UUID/versions/[0-9]+\\.corrupt-[0-9TZ-]+\\.json|bench/(cases|results|sealed)/.+|probe/.+)$"
# Atomic writes leave nothing behind; macOS may add a .DS_Store, which carries no data.
unexpected="$(cd "$DIR" && find . -type f ! -name .DS_Store | sed 's|^\./||' | grep -Ev "$ALLOWED" || true)"
if [ -n "$unexpected" ]; then
  echo "✗ files PRODUCT §7 does not list in $DIR:" >&2
  echo "$unexpected" | sed 's/^/    /' >&2
  exit 1
fi
count="$(cd "$DIR" && find . -type f ! -name .DS_Store | wc -l | tr -d ' ')"
echo "✓ $count files, every one of a kind PRODUCT §7 lists"
