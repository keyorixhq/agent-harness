#!/usr/bin/env python3
"""stop_gate.py -- STOP-GATE-1 (2026-11-24; the owner wants sessions unable to end without pushing, and wants that checked).
Stop hook of sandboxed sessions, runs BEFORE session_status.py. Why: a session wrote "<TAG> DONE (#PR_PLACEHOLDER)" with 4 commits that
were never pushed and no PR; a MERGE-FIX-AUTO-#N session left its fix commit in its workspace and the PR stayed red for 4 hours. The post-exit "Exit check" only
wrote a line nobody read.

The gate applies only when the session's last message DECLARES it is finished ("<TAG> DONE"); a session that stops to ask a question is never held.
At that moment it blocks the stop (decision "block", the reason goes back to the session) when
  1. the DONE line still holds a placeholder ("PLACEHOLDER", "(#pr)", "#PR_..."), or
  2. a clone in the workspace has work whose content is not on GitHub (bin/unpushed-content.py, the same test as the exit check, committed and uncommitted)
     and the session did not explain it (NEEDS COORDINATOR / NEEDS ADMIN / NOT PUSHED because ... / a reports/SESSION-<TAG>-ci.patch for a .github change).
Review sessions and sessions that pushed everything pass untouched. At most 2 blocks per session, then it lets go (and logs it), so it can never trap a session.
Mode file watchdog/STOP-GATE-MODE: off | shadow (log only) | on. Default when the file is missing: shadow. Any internal error: allow (fail open).
Log: watchdog/stop-gate.log. Input: Claude Code hook JSON on stdin. Output: {"decision":"block","reason":...} on stdout, exit 0, or nothing."""
import json, os, re, subprocess, sys, time

P = os.path.expanduser(os.environ.get("KX_P", "~/proj/prompts"))
W = P + "/watchdog"
WORK = os.environ.get("STOP_GATE_WORK", os.path.expanduser("~/proj/work"))
MAX_BLOCKS = 2
PLACEHOLDER = re.compile(r"PLACEHOLDER|\(#pr\)|#PR_|\(#\?+\)|\(#N+\)|\(#TBD\)", re.I)
EXPLAINED = re.compile(r"NEEDS (COORDINATOR|ADMIN|OWNER)|NOT PUSHED because|not pushed because|ci\.patch", re.I)


def log(msg):
    try:
        with open(W + "/stop-gate.log", "a") as f: f.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg))
    except Exception: pass


def mode():
    try: m = open(W + "/STOP-GATE-MODE").read().split()[0].lower()
    except Exception: m = "shadow"
    return m if m in ("off", "shadow", "on") else "shadow"


def last_assistant_text(path):
    try: lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except Exception: return ""
    for line in reversed(lines[-400:]):
        try: j = json.loads(line)
        except ValueError: continue
        if j.get("type") != "assistant": continue
        c = (j.get("message") or {}).get("content")
        if isinstance(c, list):
            t = "\n".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text").strip()
            if t: return t
        elif isinstance(c, str) and c.strip(): return c.strip()
    return ""


def unpushed(ws):
    out = []
    try: names = sorted(os.listdir(ws))
    except Exception: return out
    for n in names:
        if n.startswith("."): continue                       # .redproof-* and other scratch dirs
        c = os.path.join(ws, n)
        if not os.path.isdir(os.path.join(c, ".git")) and not os.path.isfile(os.path.join(c, ".git")): continue
        for extra in ([], ["--worktree"]):
            try:
                r = subprocess.run(["python3", P + "/bin/unpushed-content.py", c] + extra, capture_output=True, text=True, timeout=60)
                for l in r.stdout.splitlines():
                    if l.strip(): out.append("%s: %s" % (n, l.strip()[:220]))
            except Exception: pass
    return out


def main():
    try: d = json.load(sys.stdin)
    except Exception: d = {}
    tag = os.environ.get("KEYORIX_TAG", "")
    if not tag: return                                    # not a sandboxed session
    if tag.startswith("REVIEW-"): return                  # reviews write a report, they never push
    m = mode()
    if m == "off": return
    last = last_assistant_text(d.get("transcript_path") or "")
    done_lines = [l for l in last.splitlines() if re.search(re.escape(tag) + r"\s+DONE", l)]
    if not done_lines: return                              # not finished: a question or a pause, never held
    problems = []
    ph = [l.strip() for l in done_lines if PLACEHOLDER.search(l)]
    if ph: problems.append("your DONE line still holds a placeholder: %r" % ph[0][:160])
    explained = bool(EXPLAINED.search(last))
    if not explained:
        try: explained = bool(EXPLAINED.search(open("%s/reports/SESSION-%s.md" % (P, tag), errors="replace").read()[-6000:]))
        except Exception: pass
    un = unpushed(os.path.join(WORK, tag))
    if un and not explained: problems.append("work that is not on GitHub: " + " | ".join(un[:3]))
    if not problems:
        log("%s PASS (done line clean, nothing unpushed%s)" % (tag, ", explained" if un else "")); return
    cnt_f = "%s/stop-gate/%s.n" % (W, tag)
    try: n = int(open(cnt_f).read().strip() or 0)
    except Exception: n = 0
    if m == "shadow":
        log("%s SHADOW would block (#%d): %s" % (tag, n + 1, "; ".join(problems))); return
    if n >= MAX_BLOCKS:
        log("%s GAVE UP after %d blocks, letting the session end: %s" % (tag, n, "; ".join(problems))); return
    try:
        os.makedirs(os.path.dirname(cnt_f), exist_ok=True); open(cnt_f, "w").write(str(n + 1))
    except Exception: pass
    log("%s BLOCK #%d: %s" % (tag, n + 1, "; ".join(problems)))
    reason = ("STOP-GATE-1: you wrote '%s DONE' but the work is not finished: %s. "
              "Push the commits with kpush and open the PR (kgh pr create), then rewrite your DONE line with the real PR number. "
              "If you truly cannot push (a .github/** change, a refused content gate), leave reports/SESSION-%s-ci.patch or the files, and write "
              "'NEEDS COORDINATOR: <what is not pushed and why>' in your final message before the DONE line. "
              "This check lets go after %d blocks." % (tag, "; ".join(problems), tag, MAX_BLOCKS))
    print(json.dumps({"decision": "block", "reason": reason}))


if __name__ == "__main__":
    try: main()
    except Exception as e:
        log("internal error (allowed): %r" % (e,))
    sys.exit(0)
