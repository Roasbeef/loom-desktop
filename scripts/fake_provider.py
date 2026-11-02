#!/usr/bin/env python3
"""A scripted OpenAI-compatible model endpoint for driving the app offline.

It lets a test daemon run real sessions with no credential and no spend. A user
turn containing "escalate" answers with a write outside the workspace, which policy refuses,
so the approval path can be exercised. A tool result is acknowledged in text.
Anything else streams a short markdown reply.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def chunk(delta, finish=None):
    return {
        "id": "chatcmpl-fake",
        "object": "chat.completion.chunk",
        "created": int(time.time()),
        "model": "fake",
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }


def script(messages):
    """Chooses the reply from the last message of the conversation."""
    last = messages[-1] if messages else {}
    if last.get("role") == "tool":
        yield chunk({"content": "The tool returned; that is the end of this scripted run."})
        yield chunk({}, "stop")
        return
    text = json.dumps(last.get("content", ""))
    if "escalate" in text:
        args = json.dumps({"path": "/Users/Shared/loom-desktop-escalation-test", "content": "hello"})
        call = {"index": 0, "id": "call-1", "type": "function",
                "function": {"name": "fs_write", "arguments": args}}
        yield chunk({"tool_calls": [call]})
        yield chunk({}, "tool_calls")
        return
    reply = ("Here is a **scripted** reply with `inline code`.\n\n"
             "```swift\nprint(\"hello from the fake provider\")\n```\n\nDone.")
    for word in reply.split(" "):
        yield chunk({"content": word + " "})
        time.sleep(0.05)
    yield chunk({}, "stop")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length) or b"{}")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        for event in script(request.get("messages", [])):
            self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True

    def log_message(self, fmt, *args):
        sys.stderr.write("fake-provider: " + fmt % args + "\n")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18999
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
