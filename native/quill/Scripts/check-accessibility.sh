#!/bin/bash
#
# Quill's accessibility check (PLAN P5-T3): opens every surface of the debug app with
# QUILL_DUMP_A11Y — the onboarding steps, the Settings panes, the picker in its main
# states — reads the real accessibility tree VoiceOver reads, and fails on any control
# without a name, any button under 14 pt, or a surface that did not reach the screen.
# Needs a graphical session (an unlocked screen); it says so instead of guessing.
#
#   Scripts/check-accessibility.sh [path/to/debug/Quill.app]
#   Scripts/check-accessibility.sh --dump <file>    checks an existing dump (and keeps one with --keep <file>)
#
set -euo pipefail

QUILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUMP=""
KEEP=""
APP="$QUILL/build/debug/Quill.app"
while [ $# -gt 0 ]; do
  case "$1" in
    --dump) DUMP="${2:?--dump needs a file}"; shift ;;
    --keep) KEEP="${2:?--keep needs a file}"; shift ;;
    *) APP="$1" ;;
  esac
  shift
done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/quill-a11y.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "✗ $*" >&2; exit 1; }

if [ -z "$DUMP" ]; then

[ -x "$APP/Contents/MacOS/Quill" ] || fail "no debug bundle at $APP — run Scripts/make-app.sh debug"
case "$(strings "$APP/Contents/MacOS/Quill")" in
  *QUILL_DUMP_A11Y*) ;;
  *) fail "$APP is a release build: the dump hook is compiled out of it" ;;
esac

mkdir -p "$WORK/data"
QUILL_DUMP_A11Y=1 QUILL_DATA_DIR="$WORK/data" "$APP/Contents/MacOS/Quill" -AppleLanguages '(es)' >"$WORK/dump.txt" 2>&1 &
PID=$!
for _ in $(seq 1 120); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.5
done
if kill -0 "$PID" 2>/dev/null; then
  kill "$PID" 2>/dev/null || true
  fail "the dump did not finish within 60 s"
fi
OUT="$WORK/dump.txt"
[ -z "$KEEP" ] || cp "$OUT" "$KEEP"
# What the app wrote while going through every surface is only what PRODUCT §7 lists.
"$QUILL/Scripts/check-data-folder.sh" "$WORK/data" | sed 's/^/  data folder: /' \
  || fail "the data folder holds files PRODUCT §7 does not list"
else
  OUT="$DUMP"
fi

if grep -q '^A11Y ERROR' "$OUT"; then
  grep '^A11Y ERROR' "$OUT" | sed 's/^A11Y ERROR/  /' >&2
  echo "✗ could not measure: a surface did not reach the screen (a graphical session is needed)" >&2
  exit 2
fi
grep -q '^A11Y DONE' "$OUT" || { tail -20 "$OUT" >&2; fail "the dump stopped before the end"; }

# Every surface, with a tree of its own (a floor, so an empty walk cannot pass).
SURFACES="onboarding.welcome onboarding.accessibility onboarding.provider onboarding.shortcut onboarding.practice
settings.general settings.providers settings.profiles settings.apps settings.about
picker.ready picker.generating picker.noChanges picker.flagged picker.consent picker.correcting picker.failed picker.refused"
for surface in $SURFACES; do
  total="$(sed -n "s/^A11Y TOTAL $surface \([0-9]*\)$/\1/p" "$OUT")"
  [ -n "$total" ] || fail "$surface was not dumped"
  [ "$total" -ge 4 ] || fail "$surface published only $total elements"
done

# A control VoiceOver cannot name is a control a VoiceOver user cannot use.
CONTROLS='AXButton|AXCheckBox|AXRadioButton|AXPopUpButton|AXMenuButton|AXComboBox|AXSlider|AXTextField|AXTextArea|AXLink|AXDisclosureTriangle|AXIncrementor'
# The window's own buttons and a scroll bar's parts are named by the system from their
# subrole, which VoiceOver reads; everything else must carry a name of its own.
SYSTEM='AXCloseButton|AXMinimizeButton|AXZoomButton|AXFullScreenButton|AXIncrementArrow|AXDecrementArrow|AXIncrementPage|AXDecrementPage'
unnamed="$(awk -v controls="^($CONTROLS)$" -v exempt="^($SYSTEM)$" \
  '$1 == "A11Y" && $2 != "TOTAL" && $2 != "DONE" && $4 ~ controls && $5 !~ exempt && NF <= 6' "$OUT")"
if [ -n "$unnamed" ]; then
  echo "✗ controls without a name for VoiceOver:" >&2
  echo "$unnamed" | sed 's/^/    /' >&2
  exit 1
fi

small="$(awk -v exempt="^($SYSTEM)$" '$1 == "A11Y" && $4 == "AXButton" && $5 !~ exempt { split($6, d, "x"); if (d[1] > 0 && (d[1] < 14 || d[2] < 14)) print }' "$OUT")"
if [ -n "$small" ]; then
  echo "✗ buttons under the 14 pt minimum:" >&2
  echo "$small" | sed 's/^/    /' >&2
  exit 1
fi

count="$(awk -v controls="^($CONTROLS)$" -v exempt="^($SYSTEM)$" '$1 == "A11Y" && $4 ~ controls && $5 !~ exempt' "$OUT" | wc -l | tr -d ' ')"
echo "✓ $(echo "$SURFACES" | wc -w | tr -d ' ') surfaces, $count controls, every one named and at least 14 pt"
