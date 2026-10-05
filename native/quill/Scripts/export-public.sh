#!/bin/bash
#
# Exports Quill's public repository (github.com/rrios-dev/quill) from the monorepo.
#
# The monorepo stays the source of truth; the public repository receives one snapshot per
# release on its own history. The snapshot keeps the monorepo's layout, so every relative
# path in the code, the scripts and the tests holds without edits:
#
#   native/quill/                  the package (everything tracked, minus the export markers)
#   native/packages/{AppCore,GlassUI}   the two Ámbar libraries Quill reuses
#   native/Package.swift           a package that declares only those two (public/Package.swift)
#   native/Scripts/                the shared localization check Quill's own check calls
#   docs/initiatives/quill/        the design documents the tests and the code cite
#
# Usage: native/quill/Scripts/export-public.sh <destination>   (its .git is left alone)
set -euo pipefail

QUILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE="$(cd "$QUILL/.." && pwd)"
REPO="$(cd "$NATIVE/.." && pwd)"
DEST="${1:?usage: export-public.sh <destination>}"
mkdir -p "$DEST"
find "$DEST" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +

# Copies the tracked files under a path of the monorepo, keeping their relative location.
copy_tracked() {
  local path="$1"
  ( cd "$REPO" && git ls-files -z -- "$path" ) | while IFS= read -r -d '' file; do
    case "$file" in
      */.not-exported|native/quill/public/*) continue ;;
    esac
    mkdir -p "$DEST/$(dirname "$file")"
    cp -p "$REPO/$file" "$DEST/$file"
  done
}

copy_tracked native/quill
copy_tracked native/packages/AppCore
copy_tracked native/packages/GlassUI
copy_tracked docs/initiatives/quill
for script in check-localization.sh untranslated.py unknown-keys.py untranslated-allowed.txt; do
  copy_tracked "native/Scripts/$script"
done

cp "$QUILL/public/Package.swift" "$DEST/native/Package.swift"
cp "$QUILL/public/README.md" "$DEST/README.md"
cp "$QUILL/public/gitignore" "$DEST/.gitignore"
cp "$NATIVE/LICENSE" "$DEST/LICENSE"
mkdir -p "$DEST/.github/workflows" "$DEST/docs"
cp "$QUILL/public/ci.yml" "$DEST/.github/workflows/ci.yml"
cp "$QUILL/assets/brand/png/app-icon-256.png" "$DEST/docs/icon.png"

echo "exported to $DEST"
