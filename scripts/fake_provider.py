#!/usr/bin/env python3
"""A scripted OpenAI-compatible model endpoint for driving the app offline.

It lets a test daemon run real sessions with no credential and no spend. Each
keyword in the last user turn selects a script:

  escalate   a write outside the workspace, which policy refuses
  demo       a realistic multi-step run: reads, a shell command, a real edit,
             then a markdown report with headings, a list, a table and code
  long       streams about 4000 words at speed, for measuring frame drops
  slow       like the default reply, but slow enough to catch mid-stream
  hang       streams one word, then waits long enough to be stopped
  explode    answers HTTP 400, for a run that fails without retries
  todoboard  builds a phased todo board with the `todo` tool, then finishes one task
  writenote  writes a typed note with the `remember` tool
  proposerule queues a standing rule with the `propose` tool
  heartbeat  creates a recurring schedule with `schedule_create`
  commitwork writes a file and commits it, for the committed-in-this-session patch
  backgroundjob starts a background shell job that outlives the run
  think      streams three lines of reasoning, a second apart, then answers
  tour       a write, a command and a read that fails, then a short answer
  program    a code_mode call with a small program
  spawnagent starts a subagent with `agent_spawn`, waits for its report, then answers
  stopmid    one finished step, then a reply that hangs, for a turn the person stops
  readpicture reads pixel.png from the workspace, which returns an image
  slowstep   a shell command that runs for several seconds, for a step still going
  cachehit   an ordinary reply whose usage reports a large cached prefix
  cachemiss  an ordinary reply whose usage reports that prefix billed again
  markdown   a reply with an alert, a footnote, a link and a diagram

Anything else streams a short markdown reply. A tool result continues whichever
script produced the call.
"""
import json
import re
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


def call(index, name, arguments):
    return chunk({"tool_calls": [{
        "index": index,
        "id": f"call-{time.time_ns()}-{index}",
        "type": "function",
        "function": {"name": name, "arguments": json.dumps(arguments)},
    }]})


def text_stream(text, delay=0.012):
    for word in text.split(" "):
        yield chunk({"content": word + " "})
        if delay:
            time.sleep(delay)
    yield chunk({}, "stop")


REPORT = """## Retry budget is now per host

The fetcher retried without any bound, so one slow host could hold every worker. I added a **per-host budget** and a jittered backoff.

### What changed

- `fetch.py` wraps each request in a bounded retry loop.
- `BUDGET` caps attempts at three per host, per minute.
- A host over budget fails fast instead of queueing.

| Case | Before | After |
|---|---|---|
| Healthy host | 1 attempt | 1 attempt |
| Flaky host | unbounded | at most 3 |
| Dead host | blocks workers | fails in 40 ms |

### The core of it

```python
def fetch(url, budget=BUDGET):
    for attempt in range(budget):
        try:
            return get(url, timeout=2.0)
        except Timeout:
            time.sleep(backoff(attempt))
    raise BudgetExceeded(url)
```

> The budget resets on a timer rather than on success, so a host that recovers cannot immediately stampede.

All 12 tests pass. Want me to wire the budget into the metrics dashboard next?"""

LONG = " ".join(
    f"Paragraph {i} walks through the `session_channel` credit rule and why a **stop-and-wait** lane keeps replies ordered."
    + ("\n\n" if i % 4 == 3 else "")
    for i in range(240)
)


PROGRAM = """import cap/proc
import cap/report

pub fn main() -> report.Outcome {
  case proc.run(proc.command(["/bin/sh", "-c", "echo program-ran"])) {
    Ok(output) -> report.text(output.stdout)
    Error(_) -> report.failure("the command did not run")
  }
}
"""

MARKDOWN = """> [!WARNING]
> The budget resets on a timer, so check the clock first.

The design is in the notes[^1], and the docs are at [the Loom site](https://example.com/loom) and [a script](javascript:alert(1)).

[^1]: The notes live in the session store.

```mermaid
graph TD
  A[Prompt] --> B[Reply]
```"""


def last_tool_text(messages):
    for message in reversed(messages):
        if message.get("role") == "tool":
            content = message.get("content", "")
            return content if isinstance(content, str) else json.dumps(content)
    return ""


def is_prompt(message):
    """Whether a user message is something a person wrote. The daemon also writes user
    messages: the notes index at run start, and the image a tool returned. Neither
    carries the keyword in the prompt it follows."""
    if message.get("role") != "user":
        return False
    content = message.get("content", "")
    if isinstance(content, list) and not any(part.get("type") == "text" for part in content):
        return False
    text = json.dumps(content)
    return "Notes saved in this repository" not in text and "Images from tool call" not in text


def steps_taken(messages):
    """Counts tool results since the last prompt."""
    count = 0
    for message in reversed(messages):
        if is_prompt(message):
            break
        if message.get("role") == "tool":
            count += 1
    return count


def last_user_text(messages):
    for message in reversed(messages):
        if is_prompt(message):
            return json.dumps(message.get("content", ""))
    return ""


def script(messages):
    """Chooses the next reply from where the conversation stands."""
    prompt = last_user_text(messages)
    steps = steps_taken(messages)

    # The advisor is fed a digest of the primary's turn, which repeats the
    # primary's own words. It must not act them out a second time.
    if "[advisor feed" in prompt:
        yield from text_stream("Nothing to add.")
        return

    if "spawnagent" in prompt:
        if steps == 0:
            yield chunk({"content": "I will hand the survey to a subagent."})
            yield call(0, "agent_spawn", {"purpose": "survey files", "brief": "Name one file in the workspace and reply with a single short sentence."})
            yield chunk({}, "tool_calls")
        elif steps == 1:
            handle = re.search(r"sub:[^\s\"#]+#[A-Za-z0-9_-]+", last_tool_text(messages))
            yield call(0, "agent_wait", {"handles": [handle.group(0) if handle else "missing"], "within_ms": 60000})
            yield chunk({}, "tool_calls")
        else:
            yield from text_stream("The subagent has reported.")
        return

    if "stopmid" in prompt:
        if steps == 0:
            yield call(0, "bash", {"command": "echo first-step"})
            yield chunk({}, "tool_calls")
        else:
            yield chunk({"content": "Working on it. "})
            time.sleep(30)
            yield chunk({}, "stop")
        return

    if "readpicture" in prompt:
        if steps == 0:
            yield call(0, "fs_read", {"path": "pixel.png"})
            yield chunk({}, "tool_calls")
        else:
            yield from text_stream("I looked at the picture.")
        return

    if "slowstep" in prompt:
        if steps == 0:
            yield call(0, "bash", {"command": "sleep 7; echo slow-step-done"})
            yield chunk({}, "tool_calls")
        else:
            yield from text_stream("The slow step finished.")
        return

    if "markdown" in prompt:
        yield from text_stream(MARKDOWN)
        return

    if "think" in prompt:
        for line in ("First, consider the retry budget.\n", "Second, check the per-host limits.\n", "Third, decide what to change.\n"):
            yield chunk({"reasoning_content": line})
            time.sleep(1.6)
        yield from text_stream("After thinking it through, the answer is **forty-two**.")
        return

    if "tour" in prompt:
        if steps == 0:
            yield chunk({"content": "I will write a note, run a command, then read a file."})
            yield call(0, "fs_write", {"path": "tour-notes.txt", "content": "alpha\nbeta\ngamma\ndelta\n"})
            yield chunk({}, "tool_calls")
        elif steps == 1:
            yield call(0, "bash", {"command": "echo tour-command-output"})
            yield chunk({}, "tool_calls")
        elif steps == 2:
            yield call(0, "fs_read", {"path": "no-such-file-for-the-tour.txt"})
            yield chunk({}, "tool_calls")
        else:
            yield from text_stream("The tour is done.")
        return

    if "program" in prompt:
        if steps == 0:
            yield call(0, "code_mode", {"program": PROGRAM, "within_ms": 20000})
            yield chunk({}, "tool_calls")
        else:
            yield from text_stream("The program has run.")
        return

    if "demo" in prompt:
        if steps == 0:
            yield chunk({"content": "I'll look at how the fetcher handles failures, then add a bounded retry."})
            yield call(0, "bash", {"command": "ls -la"})
            yield chunk({}, "tool_calls")
        elif steps == 1:
            yield call(0, "fs_write", {"path": "fetch.py", "content": "import time\n\nBUDGET = 3\n\n\ndef fetch(url, budget=BUDGET):\n    for attempt in range(budget):\n        try:\n            return get(url, timeout=2.0)\n        except Timeout:\n            time.sleep(backoff(attempt))\n    raise BudgetExceeded(url)\n"})
            yield chunk({}, "tool_calls")
        elif steps == 2:
            yield chunk({"content": "Now the tests."})
            yield call(0, "bash", {"command": "python3 -c \"print('12 passed in 0.31s')\""})
            yield chunk({}, "tool_calls")
        else:
            yield from text_stream(REPORT)
        return

    if "todoboard" in prompt:
        if steps == 0:
            yield chunk({"content": "I will plan this first."})
            yield call(0, "todo", {"op": "init", "phases": [
                {"name": "Build", "items": ["Write the parser", "Add the tests", "Wire the metrics"]},
                {"name": "Review", "items": ["Read the diff"]},
            ]})
            yield chunk({}, "tool_calls")
        elif steps == 1:
            yield call(0, "todo", {"op": "done", "task": "Write the parser"})
            yield chunk({}, "tool_calls")
        else:
            yield from text_stream("The plan is recorded and the first task is finished.")
        return

    if "writenote" in prompt:
        if steps == 0:
            yield call(0, "remember", {
                "title": "Retry budget lives in fetch",
                "description": "the per-host budget is enforced in fetch.py",
                "kind": "decision",
                "note": "The retry budget is enforced in fetch.py, not in the callers, so every host shares one rule.",
            })
            yield chunk({}, "tool_calls")
        else:
            yield from text_stream("I wrote that down for later sessions.")
        return

    if "proposerule" in prompt:
        if steps == 0:
            yield call(0, "propose", {
                "new": "Run make check before pushing.",
                "rationale": "the last two pushes failed CI on formatting",
            })
            yield chunk({}, "tool_calls")
        else:
            yield from text_stream("I queued a standing rule for you to review.")
        return

    if "heartbeat" in prompt:
        if steps == 0:
            yield call(0, "schedule_create", {
                "name": "heartbeat",
                "body": "report where the work has got to",
                "every_seconds": 3600,
                "max_fires": 24,
            })
            yield chunk({}, "tool_calls")
        else:
            yield from text_stream("The heartbeat is scheduled.")
        return

    if "commitwork" in prompt:
        if steps == 0:
            yield call(0, "fs_write", {"path": "fetch.py", "content": "BUDGET = 3\n"})
            yield chunk({}, "tool_calls")
        elif steps == 1:
            yield call(0, "bash", {"command": "git add -A && git -c user.name=loom -c user.email=loom@example.com commit -q -m 'add the retry budget'"})
            yield chunk({}, "tool_calls")
        else:
            yield from text_stream("I committed the work.")
        return

    if "backgroundjob" in prompt:
        if steps == 0:
            yield call(0, "bash", {"command": "sleep 300", "mode": "background"})
            yield chunk({}, "tool_calls")
        else:
            yield from text_stream("A background job is running.")
        return

    if "escalate" in prompt:
        if steps == 0:
            args = {"path": "/Users/Shared/loom-desktop-escalation-test", "content": "hello"}
            yield call(0, "fs_write", args)
            yield chunk({}, "tool_calls")
        else:
            yield chunk({"content": "That write was refused, so I am waiting on your approval."})
            yield chunk({}, "stop")
        return

    if "hang" in prompt:
        yield chunk({"content": "Starting. "})
        time.sleep(30)
        yield chunk({}, "stop")
        return

    if "long" in prompt:
        yield from text_stream(LONG, delay=0.004)
        return

    delay = 0.25 if "slow" in prompt else 0.03
    yield from text_stream(
        "Here is a **scripted** reply with `inline code`.\n\n"
        "```swift\nprint(\"hello from the fake provider\")\n```\n\nDone.",
        delay,
    )


def usage_for(prompt):
    """Token counts for a reply. A cached prefix is what the app's cache outlook reads."""
    if "cachehit" in prompt:
        return {"prompt_tokens": 12500, "completion_tokens": 300, "total_tokens": 12800,
                "prompt_tokens_details": {"cached_tokens": 12000}}
    if "cachemiss" in prompt:
        return {"prompt_tokens": 12500, "completion_tokens": 300, "total_tokens": 12800,
                "prompt_tokens_details": {"cached_tokens": 0}}
    return {"prompt_tokens": 1200, "completion_tokens": 300, "total_tokens": 1500}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length) or b"{}")
        if "explode" in last_user_text(request.get("messages", [])):
            body = b'{"error": {"message": "scripted provider failure"}}'
            self.send_response(400)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            for event in script(request.get("messages", [])):
                self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            # The client stopped the run, which is a normal end to a stream.
            self.close_connection = True
            return
        # A usage chunk, as a provider sends with stream options, so the session
        # has token counts and the configured price turns them into an estimate.
        usage = {"id": "chatcmpl-fake", "object": "chat.completion.chunk", "created": int(time.time()),
                 "model": "fake", "choices": [],
                 "usage": usage_for(last_user_text(request.get("messages", [])))}
        self.wfile.write(f"data: {json.dumps(usage)}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True

    def log_message(self, fmt, *args):
        sys.stderr.write("fake-provider: " + fmt % args + "\n")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18999
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
