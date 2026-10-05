#!/usr/bin/env python3
"""A minimal Chat Completions server for exercising Quill's hosted path (PLAN P3-T3).

It listens on 127.0.0.1 only — never a LAN address, which would raise the Local Network
prompt — and answers `GET /v1/models` and `POST /v1/chat/completions`, streamed (SSE)
or not. Its answer is the user message with its first letter capitalised and a final
period, so a rewrite is visibly different and passes the guards. Nothing it receives
is stored or printed beyond a one-line request log without the text.

Run it, and seed it into an isolated data directory as a custom provider:

    Scripts/mock-chat-server.py --port 8765 --seed /tmp/quill-mock

then launch the debug app with `QUILL_DATA_DIR=/tmp/quill-mock` and
`QUILL_TREAT_LOOPBACK_AS_REMOTE=1`, so the loopback server goes through consent,
waiting to start and the cost estimate as a hosted provider would.

Behaviour switches, per request, through the model id:
    mock          the rewrite described above (the default)
    mock-slow     the same, one word every 150 ms
    mock-length   cut off: finish_reason "length"
    mock-refuse   finish_reason "content_filter"
    mock-error    HTTP 500
"""

import argparse
import json
import os
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVER_ID = "custom-mock"
MODELS = ["mock", "mock-slow", "mock-length", "mock-refuse", "mock-error"]
CONTEXT = 32_768
# Per-token prices as OpenRouter writes them, so the cost estimate has something to show.
PRICE = {"prompt": "0.000001", "completion": "0.000002"}


def rewrite(text: str) -> str:
    text = text.strip()
    if not text:
        return text
    text = text[0].upper() + text[1:]
    return text if text.endswith((".", "!", "?")) else text + "."


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):  # noqa: A002 - the base class names it so
        sys.stderr.write("mock: %s %s\n" % (self.command, self.path))

    def send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/") != "/v1/models":
            return self.send_json(404, {"error": {"message": "not found"}})
        self.send_json(200, {"data": [
            {"id": model, "name": model, "context_length": CONTEXT, "pricing": PRICE} for model in MODELS
        ]})

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/chat/completions":
            return self.send_json(404, {"error": {"message": "not found"}})
        length = int(self.headers.get("Content-Length") or 0)
        request = json.loads(self.rfile.read(length) or b"{}")
        model = request.get("model", "mock")
        messages = request.get("messages", [])
        user = next((m.get("content", "") for m in reversed(messages) if m.get("role") == "user"), "")
        if model == "mock-error":
            return self.send_json(500, {"error": {"message": "mock failure", "type": "server_error"}})
        answer = rewrite(user)
        finish = "stop"
        if model == "mock-length":
            answer, finish = answer[: max(1, len(answer) // 2)], "length"
        elif model == "mock-refuse":
            answer, finish = "", "content_filter"
        usage = {"prompt_tokens": max(1, sum(len(m.get("content", "")) for m in messages) // 4),
                 "completion_tokens": max(1, len(answer) // 4)}

        if not request.get("stream"):
            return self.send_json(200, {"model": model, "usage": usage, "choices": [
                {"message": {"role": "assistant", "content": answer}, "finish_reason": finish}]})

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        words = answer.split(" ")
        for index, word in enumerate(words):
            piece = word if index == 0 else " " + word
            self.event({"model": model, "choices": [{"delta": {"content": piece}, "finish_reason": None}]})
            if model == "mock-slow":
                time.sleep(0.15)
        self.event({"model": model, "choices": [{"delta": {}, "finish_reason": finish}], "usage": usage})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True

    def event(self, payload):
        self.wfile.write(b"data: " + json.dumps(payload).encode() + b"\n\n")
        self.wfile.flush()


def seed(directory: str, port: int) -> None:
    """Adds the server to `settings.json` as a custom provider and makes it the global
    model, keeping every other setting. Written atomically, like Quill's own store."""
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, "settings.json")
    settings = {}
    if os.path.exists(path):
        with open(path) as handle:
            settings = json.load(handle)
    servers = [s for s in settings.get("customServers", []) if s.get("id") != SERVER_ID]
    servers.append({"id": SERVER_ID, "name": "Mock server",
                    "baseURL": "http://127.0.0.1:%d/v1" % port, "requiresAPIKey": False})
    settings["customServers"] = servers
    settings["globalModel"] = {"provider": SERVER_ID, "model": "mock"}
    settings["schemaVersion"] = 1
    handle, temporary = tempfile.mkstemp(dir=directory, prefix=".settings.")
    with os.fdopen(handle, "w") as out:
        json.dump(settings, out, indent=2, sort_keys=True)
    os.replace(temporary, path)
    print("mock: seeded %s" % path, file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--seed", metavar="DATA_DIR", help="add the server to this data directory's settings.json")
    parser.add_argument("--seed-only", action="store_true", help="seed and exit without serving")
    args = parser.parse_args()
    if args.seed:
        seed(args.seed, args.port)
    if args.seed_only:
        return
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print("mock: serving on http://127.0.0.1:%d/v1" % args.port, file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
