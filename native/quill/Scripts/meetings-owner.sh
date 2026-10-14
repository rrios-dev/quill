#!/bin/bash
# Tier T4 of docs/initiatives/quill/TESTING-MEETINGS.md: the microphone, which only a
# person can test. The bench meeting plays out loud (in your headphones or on the
# speakers, wherever the Mac's output is) while you read tools/MeetingBench/owner-script.txt
# into the microphone. Quill captures both channels; the score says how well your voice
# was transcribed and how much of the meeting leaked into "Yo".
#
#   Scripts/meetings-owner.sh [seconds]     (default 120)
#
# Run it twice: once with headphones, once on the speakers.
set -euo pipefail

SECONDS_TO_LISTEN="${1:-120}"
cd "$(dirname "$0")/.."
swift build -c release --product meeting-bench >&2
BENCH="$(swift build -c release --show-bin-path)/meeting-bench"
APP="$(Scripts/make-app.sh debug 2>/dev/null)"
AUDIO="$("$BENCH" live-audio c2-es)"

WORK="$(mktemp -d)"
mkdir -p "$WORK/data"
ln -s "$HOME/Library/Caches/QuillMeetingBench/models" "$WORK/data/models"
REPORT="$WORK/owner.txt"

echo
echo "Lee este texto en voz alta, a tu ritmo, cuando empiece a sonar la reunión:"
echo
fold -s -w 90 tools/MeetingBench/owner-script.txt
echo
read -r -p "Pulsa ↩ para empezar. " _

afplay "$AUDIO" &
PLAYER=$!
trap 'kill $PLAYER 2>/dev/null || true' EXIT
perl -e 'select(undef, undef, undef, 0.5)'
open -n -W --env "QUILL_DATA_DIR=$WORK/data" --env "QUILL_LISTEN=pid:$PLAYER" --env QUILL_LISTEN_MIC=1 \
    --env QUILL_LISTEN_SPEAKERS=auto --env "QUILL_LISTEN_SECONDS=$SECONDS_TO_LISTEN" --env "QUILL_LISTEN_REPORT=$REPORT" "$APP"
kill $PLAYER 2>/dev/null || true

grep -E "LISTEN diag mic|LISTEN captured" "$REPORT" || true
"$BENCH" score c2-es "$REPORT" --me-script tools/MeetingBench/owner-script.txt
