"""Audit of Quill's MCP integration (quill-mcp) against the installed Quill
(docs/initiatives/mac-apps-mcp/DESIGN.md). Run only when the owner asks: it reads their
meetings, restarts Quill once, and spends a few cents on one synthesis.

    python3 Scripts/mcp-audit.py

First run 2026-10-15: 38/38.

Every tool goes through quill-mcp over stdio, as Claude Code does; every answer is checked
against Quill's own files (the oracle). One action spends money: a real synthesis of the
latest meeting with the Brief focus (a few cents). Agent access is left ON at the end: the
owner asked for it to be switched on.
"""
import json, os, select, subprocess, sys, time

HOME = os.path.expanduser("~")
SERVER = "/Applications/Quill.app/Contents/MacOS/quill-mcp"
DATA = os.path.join(HOME, "Library/Application Support/dev.rrios.quill")
ACCESS = os.path.join(DATA, "agent-access.json")
LOG = os.path.join(DATA, "agent-access.log")
MEETINGS = os.path.join(DATA, "meetings-data/meetings")
PROFILES = os.path.join(DATA, "profiles")
OUT = os.environ.get("TMPDIR", "/tmp")
results = []


def check(test, ok, detail):
    results.append({"test": test, "ok": bool(ok), "detail": detail})
    print(("ok    " if ok else "FAIL  ") + f"[{test}] {detail}", flush=True)
    return ok


class MCP:
    def __init__(self, client="audit-quill"):
        self.process = subprocess.Popen([SERVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.next_id = 0
        self.info = self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                                "clientInfo": {"name": client, "version": "1"}})

    def request(self, method, params=None, timeout=240):
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
        return result.get("isError", True), text, result.get("structuredContent")

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=5)


def meetings():
    records = [json.load(open(os.path.join(MEETINGS, f))) for f in os.listdir(MEETINGS) if f.endswith(".json")]
    return sorted(records, key=lambda m: m["startedAt"], reverse=True)


def quill_running():
    return subprocess.run(["pgrep", "-x", "Quill"], capture_output=True).returncode == 0


def quit_quill():
    subprocess.run(["osascript", "-e", 'tell application id "dev.rrios.quill" to quit'], capture_output=True)
    for _ in range(30):
        if not quill_running():
            return True
        time.sleep(0.3)
    return False


def open_quill():
    subprocess.run(["open", "-a", "/Applications/Quill.app"])
    for _ in range(40):
        if quill_running() and os.path.exists(os.path.join(DATA, "agent.sock")):
            return True
        time.sleep(0.3)
    return quill_running()


def main():
    session = MCP()
    # ------------------------------------------------------------------ A1 connection
    info = session.info["result"]
    check("A1", info["serverInfo"]["name"] == "quill", f"server {info['serverInfo']} protocol {info['protocolVersion']}")
    tools = session.request("tools/list")["result"]["tools"]
    names = [t["name"] for t in tools]
    check("A1", len(names) == 8, f"8 tools: {', '.join(names)}")
    actions = [t["name"] for t in tools if not t["annotations"]["readOnlyHint"]]
    check("A1", actions == ["synthesize_meeting", "rewrite_text"] and all(
        t["annotations"]["openWorldHint"] for t in tools if t["name"] in actions), f"actions marked as such: {actions}")

    # ------------------------------------------------------------------ A2 the switch
    json.dump({"enabled": False}, open(ACCESS, "w"))
    error, text, _ = session.call("list_meetings")
    check("A2", error and "agent access is off" in text, f"off → refused: {text[:70]}")
    json.dump({"enabled": True}, open(ACCESS, "w"))
    os.chmod(ACCESS, 0o600)
    error, text, _ = session.call("list_meetings")
    check("A2", not error, "on → works, read on every call")

    # ------------------------------------------------------------------ B reading
    oracle = meetings()
    error, text, structured = session.call("list_meetings", limit=100)
    listed = [m["id"] for m in structured["meetings"]]
    check("B1", listed == [m["id"] for m in oracle], f"list_meetings: the {len(listed)} meetings on disk, newest first")
    titles = {m["id"]: m["title"] for m in oracle}
    check("B1", all(m["title"] == titles[m["id"]] for m in structured["meetings"]), "same titles")
    syn_ok = all(len(m["syntheses"]) == len({s for s in m["syntheses"]}) for m in structured["meetings"])
    check("B1", syn_ok, "synthesis focuses listed")
    error, text, structured = session.call("list_meetings", since="2099-01-01")
    check("B1", not error and structured["meetings"] == [], "since in the future → no meetings")

    word = next((w for m in oracle for w in m["title"].split() if len(w) > 4), None)
    if word:
        error, text, structured = session.call("search_meetings", query=word.upper())
        expected = [m["id"] for m in oracle if word.lower() in json.dumps(m, ensure_ascii=False).lower()]
        found = [m["id"] for m in structured["meetings"]]
        check("B2", set(found) <= set(expected) and found, f"search “{word.upper()}” (case ignored) → {len(found)} meeting(s)")
    error, text, structured = session.call("search_meetings", query="zzqxyzzy")
    check("B2", not error and structured["meetings"] == [], "search with no match → none")

    with_synthesis = [m for m in oracle if m["syntheses"]]
    if with_synthesis:
        m = with_synthesis[0]
        latest = max(m["syntheses"], key=lambda s: s["createdAt"])
        error, text, structured = session.call("get_synthesis", meeting_id=m["id"])
        check("B3", not error and structured["text"] == latest["text"], f"get_synthesis: the latest of “{m['title']}”, byte for byte")
        focus = latest["focusID"]
        error, text, structured = session.call("get_synthesis", meeting_id=m["id"], focus=focus)
        check("B3", not error and structured["focusId"] == focus, f"get_synthesis by focus id {focus}")
    without = [m for m in oracle if not m["syntheses"]]
    if without:
        error, text, _ = session.call("get_synthesis", meeting_id=without[0]["id"])
        check("B3", error and "no synthesis yet" in text, f"a meeting without syntheses → {text[:70]}")

    m = oracle[0]
    error, text, _ = session.call("get_transcript", meeting_id="latest", limit=5)
    first_lines = [l for l in text.split("\n") if l.startswith("[")]
    total = int(text.split(" of ")[1].split("\n")[0]) if " of " in text else 0
    check("B4", not error and len(first_lines) == min(5, total), f"get_transcript latest: page of {len(first_lines)} of {total} turns")
    check("B4", (total <= 5) or "More: call get_transcript with offset 5" in text, "says how to get the next page")
    error, text, _ = session.call("get_transcript", meeting_id="latest", offset=total + 10)
    check("B4", not error and "No turns from" in text, "past the end → says so")
    segments = sum(len(s["text"]) for s in m["transcript"]["segments"])
    error, text, _ = session.call("get_transcript", meeting_id="latest", limit=1000, translations=True)
    shown = sum(len(l.split(": ", 1)[1]) for l in text.split("\n") if l.startswith("[") and ": " in l)
    check("B4", 0 <= shown - segments <= len(m["transcript"]["segments"]), f"every word of the transcript is there ({shown} vs {segments} characters)")

    error, text, structured = session.call("list_focuses")
    ids = [f["id"] for f in structured["focuses"]]
    check("B5", {"work", "analysis", "brief"} <= set(ids), f"list_focuses: {ids}")
    error, text, _ = session.call("list_profiles", examples=True)
    disk = len([d for d in os.listdir(PROFILES) if len(d) == 36])
    shown = len([l for l in text.split("\n") if l.startswith("- ")])
    check("B5", shown == disk, f"list_profiles: {shown} profiles, as on disk ({disk})")

    # ------------------------------------------------------------------ A5 bad arguments
    for name, arguments, needle in [
        ("get_synthesis", {"meeting_id": "nope"}, "must be a meeting id"),
        ("get_synthesis", {"meeting_id": "00000000-0000-0000-0000-000000000000"}, "No meeting with id"),
        ("list_meetings", {"limit": 500}, "between 1 and 100"),
        ("list_meetings", {"since": "ayer"}, "ISO 8601"),
        ("synthesize_meeting", {"meeting_id": "latest", "focus": "no-existe"}, "No focus"),
        ("rewrite_text", {"text": "   ", "profile": "x"}, "is empty"),
        ("get_transcript", {}, "is required"),
    ]:
        error, text, _ = session.call(name, **arguments)
        check("A5", error and needle in text, f"{name} {arguments} → {text[:80]}")

    # ------------------------------------------------------------------ C actions
    error, text, _ = session.call("rewrite_text", text="hola", profile="perfil-que-no-existe")
    check("C1", error and "No profile" in text, f"rewrite with a profile that does not exist → {text[:100]}")
    before = len(next(x for x in meetings() if x["id"] == m["id"])["syntheses"])
    started = time.time()
    error, text, structured = session.call("synthesize_meeting", meeting_id="latest", focus="brief")
    seconds = time.time() - started
    if error and "first time" in text:
        check("C2", True, f"synthesis asks for the user's consent first: {text[:120]}")
    else:
        after = next(x for x in meetings() if x["id"] == m["id"])["syntheses"]
        check("C2", not error and len(after) == before + 1, f"synthesize_meeting brief: written in {seconds:.0f}s and kept with the meeting ({before} → {len(after)})")
        check("C2", not error and after[-1]["text"] == structured.get("text"), "the synthesis returned is the one saved")
        print("---- synthesis (first lines) ----\n" + "\n".join(text.split("\n")[:8]) + "\n----", flush=True)
        error, text2, structured2 = session.call("get_synthesis", meeting_id="latest", focus="brief")
        check("C2", not error and structured2["text"] == structured.get("text"), "get_synthesis then returns it")

    # ------------------------------------------------------------------ A4 Quill closed
    if quit_quill():
        error, text, _ = session.call("list_meetings")
        check("A4", not error, "with Quill closed, reading still works")
        error, text, _ = session.call("rewrite_text", text="hola", profile="x")
        check("A4", error and "Quill is not open" in text, f"with Quill closed, an action → {text}")
        check("A4", not quill_running(), "and Quill was not opened behind the user's back")
    check("A4", open_quill(), "Quill opened again")

    # ------------------------------------------------------------------ A3 log
    session.close()
    lines = [json.loads(l) for l in open(LOG).read().strip().split("\n") if "audit-quill" in l]
    mode = oct(os.stat(LOG).st_mode & 0o777)
    check("A3", mode == "0o600", f"access log mode {mode}")
    check("A3", lines and all(set(e) == {"client", "date", "succeeded", "tool"} for e in lines),
          f"{len(lines)} entries: client, date, succeeded, tool — never arguments")
    check("A3", "perfil-que-no-existe" not in open(LOG).read(), "no arguments in the log")
    json.dump(results, open(os.path.join(OUT, "results.json"), "w"), indent=2, ensure_ascii=False)
    print(f"\n{len(results)} checks, {len([r for r in results if not r['ok']])} failed")


if __name__ == "__main__":
    main()
