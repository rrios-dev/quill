#!/bin/bash
# Tier T3 of docs/initiatives/quill/TESTING-MEETINGS.md: a bench meeting played on this
# Mac and captured through Quill's real process tap (muted, so it is silent), then scored
# against the case's reference with the same numbers as the offline bench.
#
#   Scripts/meetings-live.sh [case] [--break-at <seconds>]
#
# --break-at kills the capture mid-meeting the way a device change does; the watchdog
# must rebuild it and keep the channels aligned. Needs the corpus (meeting-bench prepare)
# and the System Audio Recording permission for the debug Quill. No microphone is used.
set -euo pipefail

CASE="${1:-c2-es}"
BREAK_AT=""
if [ "${2:-}" = "--break-at" ]; then BREAK_AT="${3:?seconds}"; fi

cd "$(dirname "$0")/.."
swift build -c release --product meeting-bench >&2
BENCH="$(swift build -c release --show-bin-path)/meeting-bench"
APP="$(Scripts/make-app.sh debug 2>/dev/null)"
AUDIO="$("$BENCH" live-audio "$CASE")"
DURATION="$(afinfo "$AUDIO" | awk '/estimated duration/ { printf "%d", $3 + 1 }')"

WORK="$(mktemp -d)"
mkdir -p "$WORK/data"
ln -s "$HOME/Library/Caches/QuillMeetingBench/models" "$WORK/data/models"
REPORT="$WORK/live.txt"

afplay "$AUDIO" &
PLAYER=$!
trap 'kill $PLAYER 2>/dev/null || true' EXIT
# The player has to exist as an audio process before it can be tapped.
perl -e 'select(undef, undef, undef, 0.5)'

ENVIRONMENT=(--env "QUILL_DATA_DIR=$WORK/data" --env "QUILL_LISTEN=pid:$PLAYER" --env QUILL_LISTEN_MUTE=1
    --env QUILL_LISTEN_SPEAKERS=auto --env "QUILL_LISTEN_SECONDS=$DURATION" --env "QUILL_LISTEN_REPORT=$REPORT")
if [ -n "$BREAK_AT" ]; then ENVIRONMENT+=(--env "QUILL_LISTEN_BREAK_AT=$BREAK_AT"); fi
echo "▸ playing $CASE (${DURATION} s) and capturing it${BREAK_AT:+, breaking the capture at ${BREAK_AT} s}…" >&2
open -n -W "${ENVIRONMENT[@]}" "$APP"

"$BENCH" score "$CASE" "$REPORT" --gate
