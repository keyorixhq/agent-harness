#!/usr/bin/env python3
"""PostToolUse hook for sandboxed sessions: deliver new coordinator inbox lines immediately.

After every tool call, compare ~/proj/prompts/inbox/<TAG>.md with what this session has already been
shown (offset kept in /tmp/claude-inbox-seen-<TAG>). New text is returned as additionalContext, so the
session sees it on its very next step. Silent and non-blocking on any error. TAG comes from
$KEYORIX_TAG (set by run-session.sh). On the first call of a session, existing inbox content is
delivered too (a restarted session must see earlier messages).
"""
import json, os, sys

def main():
    tag = os.environ.get("KEYORIX_TAG", "")
    if not tag:
        return
    inbox = os.path.expanduser(f"~/proj/prompts/inbox/{tag}.md")
    seen_f = f"/tmp/claude-inbox-seen-{tag}"
    try:
        data = open(inbox, "rb").read()
    except OSError:
        return
    try:
        seen = int(open(seen_f).read().strip() or 0)
    except (OSError, ValueError):
        seen = 0
    if seen > len(data):  # inbox was truncated/rewritten: deliver it all again
        seen = 0
    new = data[seen:].decode("utf-8", "replace").strip()
    if not new:
        return
    open(seen_f, "w").write(str(len(data)))
    msg = ("NEW MESSAGE FROM THE COORDINATOR in your inbox (~/proj/prompts/inbox/%s.md). "
           "Read it now and follow it before continuing:\n\n%s" % (tag, new[-6000:]))
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": msg}}))

try:
    sys.stdin.read()
    main()
except Exception:
    pass
