#!/bin/bash
#
# Packs Quill into a disk image with drag-to-Applications: the installer (PLAN P6-T2).
# Adapted from Ámbar's make-dmg.sh, whose lessons it keeps: HFS+ (an APFS image will not
# open on older macOS, and the message does not say why), the window laid out by the
# Finder through AppleScript (cosmetic, so a refusal warns instead of failing), and the
# result checked by mounting it, as the user will.
#
#   Scripts/make-dmg.sh                  # after Scripts/make-app.sh release
#
# Produces build/Quill-<version>.dmg, signed with the Developer ID identity. Notarizing it
# is release.sh's job: the DMG is notarized on its own, after the app inside it.
set -euo pipefail

QUILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$QUILL/build/release/Quill.app"
BUILD="$QUILL/build"
VOLUME_NAME="Quill"

fail() { echo "✗ $1" >&2; exit 1; }
ok()   { echo "✓ $1"; }

test -d "$APP" || fail "no app at $APP — run Scripts/make-app.sh release first"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"

# Hardened Runtime, read into a variable and retried: `grep -q` under pipefail gives false
# negatives, and a read right after signing can return the old signature (Ámbar measured both).
SIGN_INFO=""
for _ in 1 2 3 4 5; do
  SIGN_INFO="$(codesign -d --verbose=4 "$APP" 2>&1 || true)"
  case "$SIGN_INFO" in *runtime*) break ;; esac
  sleep 0.4
done
case "$SIGN_INFO" in
  *runtime*) ok "the app carries the Hardened Runtime" ;;
  *) fail "the app has no Hardened Runtime: it could not be notarized inside the DMG" ;;
esac

DMG="$BUILD/Quill-$VERSION.dmg"
STAGE="$BUILD/dmg-stage"
TEMP_DMG="$BUILD/Quill-$VERSION-rw.dmg"
MOUNT_POINT=""

detach_quietly() {
  local point="$1"
  [ -n "$point" ] && [ -d "$point" ] || return 0
  for _ in 1 2 3 4 5; do
    if hdiutil detach "$point" -quiet 2>/dev/null; then return 0; fi
    sleep 1
  done
  hdiutil detach "$point" -force -quiet 2>/dev/null || true
}
cleanup() { detach_quietly "$MOUNT_POINT"; rm -rf "$STAGE"; rm -f "$TEMP_DMG"; }
trap cleanup EXIT

# The content: the app (ditto keeps the extended attributes the signature needs), the
# alias to Applications, and the window's background.
rm -rf "$STAGE"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/Quill.app"
ln -s /Applications "$STAGE/Applications"
swift "$QUILL/assets/brand/QuillBrand.swift" dmg "$STAGE/.background/background.png" \
  || fail "could not draw the window background"
ok "staged: Quill.app $VERSION + alias to /Applications"

rm -f "$TEMP_DMG"
hdiutil create -srcfolder "$STAGE" -volname "$VOLUME_NAME" -fs HFS+ -format UDRW -ov -quiet "$TEMP_DMG" \
  || fail "hdiutil could not create the working image"
MOUNT_POINT="/Volumes/$VOLUME_NAME"
hdiutil attach "$TEMP_DMG" -nobrowse -quiet || fail "could not mount the working image"

# The window: 620×400 like the background (QuillBrand.swift `installerBackground`); the
# icon positions match its arrow. Change one, change the other.
LAYOUT_APPLIED="no"
if osascript - "$VOLUME_NAME" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  set volumeName to item 1 of argv
  tell application "Finder"
    tell disk volumeName
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {200, 160, 820, 560}
      set viewOptions to the icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 96
      set background picture of viewOptions to file ".background:background.png"
      set position of item "Quill.app" of container window to {170, 170}
      set position of item "Applications" of container window to {450, 170}
      close
      open
      update without registering applications
      delay 1
    end tell
  end tell
end run
APPLESCRIPT
then
  LAYOUT_APPLIED="yes"
  ok "window laid out: background, 96 px icons, no toolbar"
else
  echo "  WARNING: the Finder could not lay out the window (it needs the Automation"
  echo "  permission). The DMG still installs: it holds Quill.app and the alias."
fi

sync
detach_quietly "$MOUNT_POINT"
MOUNT_POINT=""

rm -f "$DMG"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -ov -quiet -o "$DMG" || fail "could not compress the image"
rm -f "$TEMP_DMG"
ok "compressed: $(du -h "$DMG" | cut -f1)"

# Signed as well as the app: unsigned, Gatekeeper warns on opening the image before the
# user ever reaches the notarized app. By the identity's SHA-1, like make-app.sh (a name
# with "í" reaches codesign mis-encoded on macOS 27).
IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
IDENTITY="${CODESIGN_IDENTITY:-$(sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Developer ID Application: [^"]*".*/\1/p' <<<"$IDENTITIES" | head -1)}"
[ -n "$IDENTITY" ] || fail "no Developer ID Application identity to sign the DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG" || fail "could not sign the DMG"
codesign --verify --strict "$DMG" || fail "the DMG's signature does not verify"
ok "DMG signed"

# Checked by mounting it — in the system temp folder: mounting on the external volume the
# repository lives on fails with a CRC error (Ámbar measured it).
VERIFY_POINT="$(mktemp -d "${TMPDIR:-/tmp}/quill-dmg-verify.XXXXXX")"
hdiutil attach "$DMG" -nobrowse -readonly -quiet -mountpoint "$VERIFY_POINT" || fail "the DMG does not mount"
MOUNT_POINT="$VERIFY_POINT"
test -d "$VERIFY_POINT/Quill.app" || fail "the DMG holds no Quill.app"
[ "$(readlink "$VERIFY_POINT/Applications")" = "/Applications" ] || fail "the Applications alias is wrong"
codesign --verify --strict "$VERIFY_POINT/Quill.app" || fail "the app's signature does not verify inside the DMG"
test -f "$VERIFY_POINT/.background/background.png" || fail "the background did not travel inside the DMG"
detach_quietly "$VERIFY_POINT"
MOUNT_POINT=""
rmdir "$VERIFY_POINT" 2>/dev/null || true
ok "checked by mounting it: app, alias, signature and background"

echo "$DMG"
echo "  window laid out: $LAYOUT_APPLIED"
