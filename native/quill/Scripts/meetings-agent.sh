#!/bin/bash
# A meeting transcribed from start to synthesis-ready the way an agent drives it, through
# quill-mcp (EFFICIENCY.md E7): a bench meeting played by a stand-in meeting app, Quill's
# debug build started on a scratch data folder, then list_meeting_apps, start_listening,
# get_listening_status while it plays, stop_listening and get_transcript, all over stdio
# as Claude Code calls them. The saved meeting is scored like T3.
#
#   Scripts/meetings-agent.sh [case]
#
# Silent (the tap mutes the player), no microphone, nothing of the owner's is read.
# Needs the corpus and the System Audio Recording permission for the debug Quill.
set -euo pipefail

CASE="${1:-c4-similar}"
cd "$(dirname "$0")/.."
swift build -c release --product meeting-bench >&2
BENCH="$(swift build -c release --show-bin-path)/meeting-bench"
APP="$(Scripts/make-app.sh debug 2>/dev/null)"
AUDIO="$("$BENCH" live-audio "$CASE")"

WORK="$(mktemp -d)"
mkdir -p "$WORK/data/meetings-data"
ln -s "$HOME/Library/Caches/QuillMeetingBench/models" "$WORK/data/meetings-data/models"
echo '{"enabled": true}' > "$WORK/data/agent-access.json"
# No microphone, no translation, the bench's language.
cat > "$WORK/data/meetings-data/meeting-preferences.json" <<JSON
{"offerApps": [], "autoStartApps": [], "includeMicrophone": false, "localeIdentifier": "es_ES",
 "separateSpeakers": true, "defaultFocusID": "work", "retentionDays": 90, "showsLivePanel": true,
 "translatesLive": false}
JSON

# The stand-in meeting app.
PLAYER="$WORK/MeetingPlayer.app"
mkdir -p "$PLAYER/Contents/MacOS"
swiftc -O -o "$PLAYER/Contents/MacOS/MeetingPlayer" Scripts/fixtures/MeetingPlayer.swift
cat > "$PLAYER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.quill.meetingplayer</string>
<key>CFBundleExecutable</key><string>MeetingPlayer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$PLAYER" >/dev/null 2>&1

open -n --env "QUILL_DATA_DIR=$WORK/data" --env QUILL_LISTEN_MUTE=1 "$APP"

QUILL_DATA_DIR="$WORK/data" python3 Scripts/meetings-agent.py "$APP/Contents/MacOS/quill-mcp" "$PLAYER" "$AUDIO" "$WORK"
MEETING="$(cat "$WORK/meeting-id")"
python3 Scripts/meetings-agent.py --export "$WORK/data/meetings-data/meetings/$MEETING.json" "$WORK/report"
# Scored without the gate: a saved meeting keeps sentences, not the diarizer's turns, so
# its DER (rebuilt from word times) is not the number the gate holds; the words, who said
# them and when are (EFFICIENCY.md E7).
"$BENCH" score "$CASE" "$WORK/report"
echo "▸ work folder: $WORK" >&2
