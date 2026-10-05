#!/bin/bash
#
# Builds, notarizes and packages Quill (PLAN P6-T2).
#
#   NOTARY_PROFILE=<profile> Scripts/release.sh preflight   # build and check the app, nothing sent
#   NOTARY_PROFILE=<profile> Scripts/release.sh full        # preflight, notarize the app, the DMG, check
#
# NOTARY_PROFILE names the credentials stored with `xcrun notarytool store-credentials`; no
# secret ever passes through this script. The order matters: the app is notarized and
# stapled first, so the copy inside the DMG carries its ticket; then the DMG itself, which
# Gatekeeper judges separately.
set -euo pipefail

QUILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$QUILL/build/release/Quill.app"
MODE="${1:-preflight}"

fail() { echo "✗ $1" >&2; exit 1; }
ok()   { echo "✓ $1"; }
step() { echo "▸ $1"; }

preflight() {
  step "build the release app"
  "$QUILL/Scripts/make-app.sh" release >/dev/null || fail "make-app.sh release failed"
  test -d "$APP" || fail "no app at $APP"
  codesign --verify --strict --verbose=2 "$APP" 2>/dev/null || fail "the app's signature does not verify"
  local info=""
  for _ in 1 2 3 4 5; do
    info="$(codesign -d --verbose=4 "$APP" 2>&1 || true)"
    case "$info" in *runtime*) break ;; esac
    sleep 0.4
  done
  case "$info" in *"Authority=Developer ID Application"*) ;; *) fail "not signed with a Developer ID Application identity" ;; esac
  case "$info" in *runtime*) ;; *) fail "no Hardened Runtime" ;; esac
  case "$info" in *"Timestamp="*) ;; *) fail "no secure timestamp (notarization requires it)" ;; esac
  local bundle version
  bundle="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")"
  version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
  [ "$bundle" = "dev.rrios.quill" ] || fail "bundle id is $bundle, not dev.rrios.quill (README Q1)"
  ok "Quill $version ($bundle): Developer ID, Hardened Runtime, timestamp"
}

notarize() {
  local file="$1"
  [ -n "${NOTARY_PROFILE:-}" ] || fail "NOTARY_PROFILE is not set — store one with: xcrun notarytool store-credentials"
  step "notarize $(basename "$file")"
  xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait >"$QUILL/build/notary.log" 2>&1 \
    || { cat "$QUILL/build/notary.log" >&2; fail "notarization failed — ask for the log with: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE"; }
  grep -q "status: Accepted" "$QUILL/build/notary.log" \
    || { cat "$QUILL/build/notary.log" >&2; fail "notarization did not return Accepted"; }
  ok "$(basename "$file"): Accepted"
}

full() {
  preflight
  local zip="$QUILL/build/Quill-notarize.zip"
  rm -f "$zip"
  ditto -c -k --keepParent "$APP" "$zip"
  notarize "$zip"
  rm -f "$zip"
  xcrun stapler staple "$APP" >/dev/null || fail "could not staple the app"
  spctl --assess --type execute "$APP" 2>/dev/null || fail "Gatekeeper does not accept the app"
  ok "app stapled; Gatekeeper accepts it"

  step "build the DMG"
  local dmg
  dmg="$("$QUILL/Scripts/make-dmg.sh" | tail -2 | head -1)"
  test -f "$dmg" || fail "make-dmg.sh produced no DMG"
  notarize "$dmg"
  xcrun stapler staple "$dmg" >/dev/null || fail "could not staple the DMG"
  xcrun stapler validate "$dmg" >/dev/null || fail "the DMG's ticket does not validate"
  spctl --assess --type open --context context:primary-signature "$dmg" 2>/dev/null \
    || fail "Gatekeeper does not accept the DMG"
  shasum -a 256 "$dmg" | tee "$dmg.sha256"
  ok "DMG notarized, stapled and accepted: $dmg"
}

case "$MODE" in
  preflight) preflight ;;
  full) full ;;
  *) fail "usage: release.sh preflight|full" ;;
esac
