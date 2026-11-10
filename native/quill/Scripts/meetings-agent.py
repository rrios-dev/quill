"""Driver for Scripts/meetings-agent.sh (EFFICIENCY.md E7): an agent transcribing a meeting
through quill-mcp, against Quill's debug build on a scratch data folder.

    meetings-agent.py <quill-mcp> <player.app> <audio> <work folder>
    meetings-agent.py --export <meeting.json> <report base>

The first form drives the meeting and writes <work>/meeting-id and <work>/agent.json; the
second turns the saved meeting into the files `meeting-bench score` reads.
"""
import json, os, select, subprocess, sys, time


def check(results, test, ok, detail=""):
    results.append({"test": test, "ok": bool(ok), "detail": detail})
    print(("ok    " if ok else "FAIL  ") + f"[{test}] {detail}", flush=True)


class MCP:
    def __init__(self, server):
        self.process = subprocess.Popen([server], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.next_id = 0
        self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                    "clientInfo": {"name": "meetings-agent", "version": "1"}})

    def request(self, method, params=None, timeout=300):
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            message["params"] = params
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            ready, _, _ = select.select([self.process.stdout], [], [], 0.5)
            if ready:
                reply = json.loads(self.process.stdout.readline())
                if reply.get("id") == self.next_id:
                    return reply
        raise TimeoutError(method)

    def call(self, name, **arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments}).get("result", {})
        text = "".join(c.get("text", "") for c in result.get("content", []))
        return result.get("isError", False), text, result.get("structuredContent") or {}


def duration(path):
    out = subprocess.run(["afinfo", path], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "estimated duration" in line:
            return float(line.split()[2])
    raise SystemExit("no duration for " + path)


def drive(server, player, audio, work):
    results = []
    data = os.environ["QUILL_DATA_DIR"]
    app_binary = os.path.join(os.path.dirname(server), "Quill")
    socket = os.path.join(data, "agent.sock")
    deadline = time.time() + 60
    while not os.path.exists(socket) and time.time() < deadline:
        time.sleep(0.5)
    check(results, "app", os.path.exists(socket), "the debug Quill listens for agents")
    mcp = MCP(server)
    names = [tool["name"] for tool in mcp.request("tools/list")["result"]["tools"]]
    wanted = ["list_meeting_apps", "start_listening", "get_listening_status", "stop_listening", "wait_for_meeting"]
    check(results, "tools", all(name in names for name in wanted), f"{len(names)} tools")

    error, text, _ = mcp.call("get_listening_status")
    check(results, "idle", not error and "not transcribing" in text, text.splitlines()[0] if text else "")
    error, text, _ = mcp.call("list_meeting_apps")
    check(results, "apps", not error, text.splitlines()[0] if text else "")

    length = duration(audio)
    subprocess.run(["open", "-n", player, "--args", audio], check=True)
    began = time.time()
    started = None
    while time.time() - began < 3 and started is None:
        error, text, structured = mcp.call("start_listening", app_id="app:test.quill.meetingplayer", language="es_ES")
        if not error:
            started = time.time()
        else:
            time.sleep(0.2)
    check(results, "start", started is not None, text)
    if started is None:
        return results
    error, text, _ = mcp.call("start_listening")
    check(results, "start twice", error and "already" in text, text)

    first_line = None
    drafts = 0
    polls = []
    while time.time() - began < length + 3:
        time.sleep(2)
        error, text, _ = mcp.call("get_listening_status", lines=3)
        has_line = "Last " in text
        if has_line and first_line is None:
            first_line = time.time() - began
        if "(being said)" in text:
            drafts += 1
        polls.append(text.splitlines()[0] if text else "")
    check(results, "live lines", first_line is not None,
          f"first finished line after {first_line:.1f} s of playing" if first_line else "no line")
    check(results, "drafts", drafts > 0, f"{drafts} of {len(polls)} status reads showed a sentence being said")

    stop_began = time.time()
    error, text, structured = mcp.call("stop_listening")
    stop_took = time.time() - stop_began
    meeting = structured.get("meetingId")
    check(results, "stop", not error and meeting, f"{stop_took:.1f} s to save: {text[:160]}")
    if not meeting:
        return results
    error, text, structured = mcp.call("wait_for_meeting", seconds=5)
    check(results, "wait after", structured.get("meetingId") == meeting, "wait_for_meeting returns the meeting just saved")
    error, text, _ = mcp.call("get_transcript", meeting_id=meeting, limit=5)
    check(results, "transcript", not error and "Turns 0–" in text, text.splitlines()[2] if len(text.splitlines()) > 2 else text)
    error, text, _ = mcp.call("list_meetings", limit=1)
    check(results, "listed", meeting in text, "the meeting is the newest in list_meetings")

    with open(os.path.join(work, "meeting-id"), "w") as handle:
        handle.write(meeting)
    with open(os.path.join(work, "agent.json"), "w") as handle:
        json.dump({"results": results, "first_line_seconds": first_line, "draft_reads": drafts,
                   "status_reads": len(polls), "stop_seconds": stop_took}, handle, indent=2)
    # The debug Quill this run started, by its own executable path: never another Quill.
    pids = subprocess.run(["pgrep", "-f", app_binary], capture_output=True, text=True).stdout.split()
    for pid in pids:
        subprocess.run(["kill", pid])
    return results


def export(meeting_path, base):
    with open(meeting_path) as handle:
        meeting = json.load(handle)
    transcript = meeting["transcript"]
    captured = (meeting.get("capturedSeconds") or {}).get("others", meeting["duration"])
    with open(base, "w") as handle:
        handle.write(f"LISTEN captured others={captured:.1f} s\n")
    raw = dict(transcript)
    raw["segments"] = [{key: value for key, value in segment.items() if key != "speaker"} for segment in transcript["segments"]]
    with open(base + ".raw.json", "w") as handle:
        json.dump(raw, handle)
    with open(base + ".json", "w") as handle:
        json.dump(transcript, handle)
    # The voices' turns as the words place them: a segment's own span also covers the
    # pauses inside it, which the scorer would count as speech nobody said.
    rows = []
    for segment in transcript["segments"]:
        if segment.get("channel") != "others" or not segment.get("speaker"):
            continue
        spans = [(w["start"], w["end"]) for w in segment.get("words") or []] or [(segment["start"], segment["end"])]
        rows += [{"speaker": segment["speaker"], "start": start, "end": end} for start, end in spans]
    with open(base + ".turns.json", "w") as handle:
        json.dump(rows, handle)


if __name__ == "__main__":
    if sys.argv[1] == "--export":
        export(sys.argv[2], sys.argv[3])
    else:
        outcome = drive(*sys.argv[1:5])
        failed = [r for r in outcome if not r["ok"]]
        print(f"{len(outcome) - len(failed)}/{len(outcome)} passed")
        sys.exit(1 if failed else 0)
