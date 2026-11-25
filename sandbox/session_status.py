#!/usr/bin/env python3
"""Session status hook (Stop / Notification / UserPromptSubmit) for sandboxed sessions.

Writes ~/proj/prompts/status/<TAG>.json = {tag, state, since, updated, last_message}
  state: "done"    -> last assistant message contains "<TAG> DONE"
         "waiting" -> Claude Code raised a Notification (needs input/permission), or the last message
                      asks for a decision (question at the end, "Needs owner", "What I need from you", ...)
         "working" -> otherwise / after the user answers
On a change to done/waiting: macOS notification. Silent, never blocks. TAG from $KEYORIX_TAG.
Usage in hooks: session_status.py stop | notify | prompt
"""
import json, os, re, subprocess, sys, time

ASK_RE = re.compile(r"(needs? owner|needs coordinator|what i need from you|i need (a|your) decision|"
                    r"one of these|which (one|option)|should i |do you want|please (decide|confirm)|"
                    r"i'm stopping here|stopping to ask|waiting (for|on) (you|your|a decision))", re.I)

def last_assistant_text(transcript):
    try:
        lines = open(transcript, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return ""
    for line in reversed(lines[-400:]):
        try:
            j = json.loads(line)
        except ValueError:
            continue
        if j.get("type") != "assistant":
            continue
        c = (j.get("message") or {}).get("content")
        if isinstance(c, list):
            t = "\n".join(x.get("text", "") for x in c if x.get("type") == "text").strip()
            if t:
                return t
    return ""

def notify(tag, state, text):
    title = {"done": f"{tag} is done", "waiting": f"{tag} is waiting for you"}.get(state)
    if not title:
        return
    body = re.sub(r"\s+", " ", text)[:180].replace('"', "'").replace("\\", "/")
    subprocess.run(["osascript", "-e", f'display notification "{body}" with title "{title}" sound name "Glass"'],
                   capture_output=True, timeout=10)

def main():
    tag = os.environ.get("KEYORIX_TAG", "")
    if not tag:
        return
    mode = sys.argv[1] if len(sys.argv) > 1 else "stop"
    try:
        data = json.load(sys.stdin)
    except ValueError:
        data = {}
    d = os.path.expanduser("~/proj/prompts/status"); os.makedirs(d, exist_ok=True)
    f = os.path.join(d, f"{tag}.json")
    try:
        old = json.load(open(f))
    except (OSError, ValueError):
        old = {}
    text = old.get("last_message", "")
    if mode == "prompt":
        state = "working"
    elif mode == "notify":
        text = last_assistant_text(data.get("transcript_path", "")) or data.get("message", "") or text
        state = "done" if (old.get("state") == "done" or f"{tag} DONE" in text) else "waiting"
    else:  # stop
        text = last_assistant_text(data.get("transcript_path", "")) or text
        tail = text[-1500:]
        if f"{tag} DONE" in text:
            state = "done"
        elif tail.rstrip().endswith("?") or ASK_RE.search(tail):
            state = "waiting"
        else:
            state = "working"
    now = time.strftime("%Y-%m-%d %H:%M:%S")
    rec = {"tag": tag, "state": state, "since": old.get("since", now) if old.get("state") == state else now,
           "updated": now, "last_message": text[-6000:]}
    tmp = f + ".tmp"; json.dump(rec, open(tmp, "w"), indent=1); os.replace(tmp, f)
    if state != old.get("state") and state in ("done", "waiting"):
        notify(tag, state, text)
    if state == "waiting" and state != old.get("state"):
        raise_window()

def raise_window():
    # 2026-10-17 (owner): bring a session that waits for an answer to the front. iTerm runner only;
    # ~/proj/prompts/FOCUS-OFF disables it (e.g. while owner is presenting or typing elsewhere).
    t = os.environ.get("KEYORIX_TTY", "")
    if not t.startswith("/dev/tty") or os.path.exists(os.path.expanduser("~/proj/prompts/FOCUS-OFF")):
        return
    script = ('tell application "iTerm" to repeat with w in windows\n'
              ' repeat with tb in tabs of w\n repeat with s in sessions of tb\n'
              f'  if tty of s is "{t}" then\n   set miniaturized of w to false\n   select w\n   select tb\n   select s\n   return\n  end if\n'
              ' end repeat\n end repeat\nend repeat')
    subprocess.run(["osascript", "-e", script.replace("\\n", "\n")], capture_output=True, timeout=10)
    # 2026-10-17 (owner): never steal keyboard focus: the window goes on top inside iTerm only (no activate);
    # the "is waiting for you" notification (notify()) is what tells the owner.

try:
    main()
except Exception:
    pass
