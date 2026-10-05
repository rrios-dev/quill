#!/bin/bash
#
# Assembles Quill.app from the executable SwiftPM builds, and signs it.
#
# A parameterised copy of Ámbar's Scripts/make-app.sh (ARCHITECTURE §9). There is no
# .xcodeproj on purpose: SwiftPM builds the same from the terminal, Xcode and CI; the
# .app bundle is the one thing it does not make, and that is this script.
#
#   Scripts/make-app.sh [debug|release] [--bundle-id <id>]
#
# Each configuration builds to its own folder — build/debug/Quill.app and
# build/release/Quill.app, git-ignored and outside .build — so both can exist at once.
# Progress goes to stderr; the bundle's path is the only line on stdout:
#
#   APP="$(Scripts/make-app.sh debug)"
#
set -euo pipefail

CONFIGURATION="release"
BUNDLE_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    debug|release) CONFIGURATION="$1" ;;
    --bundle-id) BUNDLE_ID="${2:?--bundle-id needs a value}"; shift ;;
    *) echo "usage: make-app.sh [debug|release] [--bundle-id <id>]" >&2; exit 64 ;;
  esac
  shift
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/$CONFIGURATION/Quill.app"
log() { echo "$@" >&2; }

cd "$ROOT"
log "▸ Building ($CONFIGURATION)…"
swift build -c "$CONFIGURATION" --product Quill >&2
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

log "▸ Assembling the bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Quill" "$APP/Contents/MacOS/Quill"
cp "$ROOT/apps/Quill/Info.plist" "$APP/Contents/Info.plist"
if [ -n "$BUNDLE_ID" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
fi

# Resource bundles go to Contents/Resources, the only place codesign accepts — in the
# bundle root it fails with "unsealed contents present in the bundle root". Code reads
# them through QuillSupport's ResourceBundle, never `Bundle.module` alone (ARCHITECTURE §8).
# Every bundle is copied, not a hand-made list, and at least the app's own must be there.
for RESOURCE_BUNDLE in "$BIN_DIR"/*.bundle; do
  [ -d "$RESOURCE_BUNDLE" ] || continue
  cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
done
if [ ! -d "$APP/Contents/Resources/Quill_Quill.bundle" ]; then
  log "✗ Quill_Quill.bundle is missing: the app would show no strings"
  exit 1
fi

# Files the system reads from the main bundle itself, not from a module's resource
# bundle: the Services menu title (ServicesMenu.strings), per language.
cp -R "$ROOT/apps/Quill/BundleResources/." "$APP/Contents/Resources/"
# The readiness labels the bench exported (ARCHITECTURE §5.1).
cp "$ROOT/tools/QuillBench/data/readiness.json" "$APP/Contents/Resources/readiness.json"
# The icon, rendered at build time from the brand's geometry (assets/brand), so the app and
# the web never drift apart.
swift "$ROOT/assets/brand/QuillBrand.swift" icns "$APP/Contents/Resources/AppIcon.icns" >&2

# Signing. Accessibility is granted per designated requirement (team + bundle id), so
# every build — debug included — is signed with the Developer ID certificate from the
# first one (ARCHITECTURE §3.5). An ad-hoc signature changes on every build and silently
# revokes the grant, so it is never used. "Ambar Local Signing" is the fallback that
# keeps the Accessibility grant but makes the Keychain prompt again after rebuilds.
# The identity list is captured in a variable, not piped into `grep -q`: with pipefail,
# grep closing the pipe early makes the pipeline fail even when it matched.
IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
CODESIGN_NAME=""
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
  # By its SHA-1, not its name: on macOS 27 a name with a non-ASCII letter ("Ríos")
  # reaches codesign mis-encoded and matches no identity. The hash is plain ASCII.
  CODESIGN_IDENTITY="$(sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Developer ID Application: [^"]*".*/\1/p' <<<"$IDENTITIES" | head -1)"
  CODESIGN_NAME="$(sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' <<<"$IDENTITIES" | head -1)"
fi
if [ -z "$CODESIGN_IDENTITY" ]; then
  case "$IDENTITIES" in
    *"Ambar Local Signing"*) CODESIGN_IDENTITY="Ambar Local Signing" ;;
  esac
fi
if [ -z "$CODESIGN_IDENTITY" ] || [ "$CODESIGN_IDENTITY" = "-" ]; then
  log "✗ No Developer ID certificate (or the local fallback identity) to sign with."
  log "  Quill is never signed ad hoc: the Accessibility grant would not survive a rebuild."
  exit 1
fi
log "▸ Signing with: ${CODESIGN_NAME:-$CODESIGN_IDENTITY}"

# --options runtime: the Hardened Runtime notarization requires. No --deep (Apple
# advises against it; there are no nested components to sign today).
# Release builds carry a secure timestamp, which notarization requires. Debug builds
# skip it so they build offline; the designated requirement — what the grant is tied
# to — is the same either way.
SIGN_ARGS=(--force --options runtime --entitlements "$ROOT/apps/Quill/Quill.entitlements")
if [ "$CONFIGURATION" = "release" ]; then
  SIGN_ARGS+=(--timestamp)
else
  SIGN_ARGS+=(--timestamp=none)
fi
codesign "${SIGN_ARGS[@]}" --sign "$CODESIGN_IDENTITY" "$APP" >&2

# Check, do not trust, that the runtime flag is on the binary. Retried: right after a
# --force signature, `codesign -d` can read the previous cached signature (measured on
# Ámbar: one false negative in three runs).
SIGN_INFO=""
for _ in 1 2 3 4 5; do
  SIGN_INFO="$(codesign -d --verbose=4 "$APP" 2>&1 || true)"
  case "$SIGN_INFO" in
    *runtime*) break ;;
  esac
  sleep 0.4
done
case "$SIGN_INFO" in
  *runtime*) ;;
  *)
    log "✗ The bundle has no Hardened Runtime; it could not be notarized."
    log "$SIGN_INFO"
    exit 1
    ;;
esac

log "✓ $APP"
echo "$APP"
