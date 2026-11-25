#!/usr/bin/env python3
"""kx-asks: one place for everything that needs admin (2026-10-17).

  kx-asks.py ask --id ID [--blocking] --q "question" --opt "a: text" --opt "b: text" --rec a [--ref "#N"] [--from TAG]
      File a question (sessions call it through `ask-admin`). Same ID again -> "also asked by", not a duplicate.
  kx-asks.py ui        The ASKS window: open asks (blocking first) + sessions + queue; answer with keys.
  kx-asks.py list      Print open asks (for the coordinator / digests).
  kx-asks.py route     Deliver answered-but-unrouted asks (called by the UI and by refill).

Files: watchdog/asks/open/ID.json, watchdog/asks/answered/ID.json, watchdog/asks/answers.log
"""
import argparse, json, os, re, subprocess, sys, time, glob, select, shutil

P = os.path.expanduser("~/proj/prompts"); W = f"{P}/watchdog"; A = f"{W}/asks"
OPEN, DONE = f"{A}/open", f"{A}/answered"
for d in (OPEN, DONE): os.makedirs(d, exist_ok=True)
now = lambda: time.strftime("%Y-%m-%d %H:%M")

def slug(s): return re.sub(r"[^A-Za-z0-9#._-]+", "-", s).strip("-")[:60]

def load(d):
    out = []
    for f in glob.glob(f"{d}/*.json"):
        try: out.append(json.load(open(f)))
        except Exception: pass
    return out

def save(d, a):
    tmp = f"{d}/.{a['id']}.tmp"; json.dump(a, open(tmp, "w"), indent=1); os.replace(tmp, f"{d}/{a['id']}.json")

def notify(title, text):
    t = text.replace('"', "'")[:200]
    subprocess.run(["osascript", "-e", f'display notification "{t}" with title "{title}" sound name "Glass"'],
                   stderr=subprocess.DEVNULL)

def infer_product(frm, ref, aid):
    """product of an ask: explicit --product wins; otherwise guessed from the asker tag / ref (dd-*, dashdiag)"""
    t = " ".join([frm or "", ref or "", aid or ""]).lower()
    if re.search(r"(^|[\s/_-])dd[-_/]|dashdiag", t): return "dashdiag"
    return "keyorix"

def cmd_ask(o):
    aid = slug(o.id); frm = o.frm or os.environ.get("KEYORIX_TAG", "coordinator")
    if os.path.exists(f"{DONE}/{aid}.json"):
        a = json.load(open(f"{DONE}/{aid}.json"))
        print(f"already answered {a['answered_at']}: {a['answer']} {a.get('note','')}".strip()); return
    path = f"{OPEN}/{aid}.json"
    if os.path.exists(path):
        a = json.load(open(path))
        if frm not in a["askers"]: a["askers"].append(frm)
        if o.product: a["product"] = o.product
        elif not a.get("product"): a["product"] = infer_product(frm, a.get("ref"), aid)
        if o.blocking and not a["blocking"]: a["blocking"] = True; notify("Keyorix: blocking ask", a["q"])
        save(OPEN, a); print(f"merged into open ask {aid} (asked by {', '.join(a['askers'])})"); return
    opts = {}
    for x in o.opt or []:
        k, _, v = x.partition(":"); opts[k.strip()] = v.strip()
    a = dict(id=aid, q=o.q, opts=opts, rec=o.rec, ref=o.ref or "", blocking=o.blocking, askers=[frm],
             asked_at=now(), why=o.why or "", product=o.product or infer_product(frm, o.ref, aid))
    save(OPEN, a)
    if auto_answer() and not os.path.exists(path):
        print(f"ask {aid} answered by the auto-policy"); return
    if o.blocking: notify("Keyorix: blocking ask", a["q"])
    print(f"filed ask {aid} ({'BLOCKING' if o.blocking else 'non-blocking'}); owner sees it in the ASKS window. "
          "Do not wait for it: record the ID under NEEDS ADMIN and carry on or end your turn; the answer is sent to you.")

def auto_answer():
    """2026-11-15 auto-policy: answer open asks whose id matches watchdog/ASK-AUTO-POLICY.txt with their own recommendation.
    Never for gate-* (owner's .github/scripts gate) or vuln-* asks, and never without a recommendation."""
    pol = f"{A}/../ASK-AUTO-POLICY.txt"
    try: pats = [l.strip() for l in open(pol) if l.strip() and not l.startswith("#")]
    except OSError: return 0
    n = 0
    for a in load(OPEN):
        aid = a.get("id", ""); ch = (a.get("rec") or "").lower()
        if not ch or ch not in a.get("opts", {}) or re.match(r"^(gate-|vuln-)", aid): continue
        if any(re.search(p, aid) for p in pats):
            note = "auto-policy: recommendation taken (owner, 2026-11-15)"
            answer(a, ch, note)
            with open(f"{A}/answers.log", "a") as f: f.write(f"{now()} {a['id']} -> {ch} {note}\n")
            n += 1
    return n

def running_tags():
    r = subprocess.run(["pgrep", "-f", "claude.*--settings .*generated/"], capture_output=True, text=True).stdout.split()
    tags = []
    for pid in r:
        c = subprocess.run(["ps", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
        m = re.search(r"generated/([A-Z0-9-]+)\.json", c)
        if m: tags.append(m.group(1))
    return tags

def cmd_route(_=None):
    live = set(running_tags()); n = 0
    for a in load(DONE):
        if a.get("routed"): continue
        if "answer" not in a:   # 2026-10-27: a couple of legacy answered/ entries were moved there outside
            a["routed"] = now(); a["routed_to"] = []; save(DONE, a); continue   # this tool; skip rather than crash the whole pass
        msg = f"[owner's answer to ask {a['id']}] {a['q']} -> {a['answer']}"
        if a["answer"] in a["opts"]: msg += f" ({a['opts'][a['answer']]})"
        if a.get("note"): msg += f". Note: {a['note']}"
        sent = []
        for t in a["askers"]:
            if t in live:
                subprocess.run(["zsh", f"{P}/bin/send-to-session", t, msg + ". Apply it, update your report, carry on."],
                               capture_output=True); sent.append(t)
        subprocess.run(["zsh", f"{P}/bin/mm-say", msg + f". Apply it to PRs it unblocks (ref {a['ref']}); "
                        "if it needs new work, write it to FOR-ADMIN as 'coordinator: route answer ID'."],
                       capture_output=True, env={**os.environ, "KEYORIX_TAG": "owner"})
        with open(f"{A}/answers.log", "a") as f:
            f.write(f"{now()} {a['id']} -> {a['answer']} {a.get('note','')} | sent to {sent or 'nobody live'} + MERGE-MASTER\n")
        with open(f"{W}/COORDINATOR-NOTES.md", "a") as f:
            f.write(f"- {now()} ANSWER {a['id']} ({a['ref']}) -> {a['answer']} {a.get('note','')}: coordinator routes follow-up work (sessions, decisions.md).\n")
        a["routed"] = now(); a["routed_to"] = sent; save(DONE, a); n += 1
    return n

def sessions_view():
    rows = []
    for t in running_tags():
        try: s = json.load(open(f"{P}/status/{t}.json"))
        except Exception: s = {}
        idle = int((time.time() - os.path.getmtime(f"{P}/status/{t}.json")) / 60) if os.path.exists(f"{P}/status/{t}.json") else -1
        rows.append((t, s.get("state", "?"), idle, (s.get("last_message") or "").replace("\n", " ")))
    return rows

def queue_line():
    try:
        q = open(f"{W}/digest.keys").read()
    except Exception: q = ""
    return ""

B, D, G, R, Y, C, X = "\033[1m", "\033[2m", "\033[32m", "\033[31m", "\033[33m", "\033[36m", "\033[0m"

def wrap(text, width, indent):
    import textwrap
    return textwrap.fill(text, width=width, initial_indent=indent, subsequent_indent=indent)

def card(asks, i, msg=""):
    cols = min(shutil.get_terminal_size((110, 40)).columns, 110)
    out = ["\033[2J\033[H"]
    nb = sum(1 for a in asks if a["blocking"])
    sys.stdout.write(f"\033]0;ASKS - {len(asks)} open, {nb} blocking\007" if asks else "\033]0;ASKS - nothing for you\007")
    out.append(f"{B}KEYORIX - QUESTIONS FOR YOU{X}   {len(asks)} open, {nb} blocking      {D}{now()}{X}")
    out.append("-" * cols)
    if not asks:
        out += ["", f"  {G}Nothing needs you right now.{X}", ""]
    else:
        a = asks[i]
        flag = f"{R}{B}BLOCKING{X}  " if a["blocking"] else f"{D}not urgent{X}  "
        out.append(f"Question {B}{i+1} of {len(asks)}{X}   {flag}{C}{a['ref']}{X}")
        out.append("")
        out.append(wrap(a["q"], cols, "  ").replace("  ", "  " + B, 1) + X)
        out.append("")
        if a.get("why"): out += [wrap("Context: " + a["why"], cols, "  "), ""]
        if a.get("blocks"): out += [wrap("Waiting on this: " + a["blocks"], cols, "  "), ""]
        out.append(wrap("Asked by: " + ", ".join(a["askers"]) + f"   (first asked {a['asked_at']})", cols, "  "))
        out.append("")
        for k, v in a["opts"].items():
            if k == a["rec"]:
                out.append(wrap(f"[{k}] {v}   <- recommended", cols, "  ").replace(f"[{k}]", f"{G}{B}[{k}]", 1) + X)
            else:
                out.append(wrap(f"[{k}] {v}", cols, "  "))
        out.append("")
        out.append("-" * cols)
        keys = "/".join(a["opts"])
        out.append(f"  Press {B}{keys}{X} to choose   {B}Enter{X} = recommended ({a['rec']})   "
                   f"{B}n{X} = choose + add a note   {B}p{X} = park")
        out.append(f"  {B}->{X} / {B}<-{X} = next / previous question   {B}o{X} = open on GitHub   "
                   f"{B}s{X} = sessions   {B}q{X} = quit")
    if msg: out += ["", f"  {Y}{msg}{X}"]
    sys.stdout.write("\n".join(out) + "\n"); sys.stdout.flush()

def sessions_screen():
    cols = shutil.get_terminal_size((110, 40)).columns
    out = ["\033[2J\033[H", f"{B}SESSIONS RUNNING{X}   (yellow = stopped 30+ min without finishing)", "-" * min(cols, 110)]
    for t, st, idle, m in sessions_view():
        col = Y if st in ("waiting", "done") and idle >= 30 else ""
        out.append(f"{col}{B}{t}{X}{col}  - {st}, {idle} min since last update{X}")
        out.append(wrap(m[:400] or "(no message yet)", min(cols, 110), "    "))
        out.append("")
    out.append("Press any key to go back.")
    sys.stdout.write("\n".join(out) + "\n"); sys.stdout.flush()

def getkey(timeout):
    import termios, tty
    fd = sys.stdin.fileno(); old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        r, _, _ = select.select([sys.stdin], [], [], timeout)
        if not r: return None
        k = os.read(fd, 1).decode(errors="ignore")
        if k == "\033":
            r, _, _ = select.select([sys.stdin], [], [], 0.05)
            if r:
                seq = os.read(fd, 2).decode(errors="ignore")
                return {"[C": "RIGHT", "[D": "LEFT", "[A": "LEFT", "[B": "RIGHT"}.get(seq, None)
            return "ESC"
        return k
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)

def answer(a, choice, note):
    a.update(answer=choice, note=note, answered_at=now()); save(DONE, a); os.remove(f"{OPEN}/{a['id']}.json")

def cmd_ui(_):
    os.system("printf '\\033]0;ASKS\\007'")
    i, msg = 0, ""
    while True:
        asks = sorted(load(OPEN), key=lambda a: (not a["blocking"], a["asked_at"]))
        i = max(0, min(i, len(asks) - 1)) if asks else 0
        card(asks, i, msg); msg = ""
        k = getkey(30)
        if k is None or not asks:
            if k == "q": return
            if k == "s": sessions_screen(); getkey(600)
            continue
        a = asks[i]
        if k == "q": return
        if k == "RIGHT": i = (i + 1) % len(asks); continue
        if k == "LEFT": i = (i - 1) % len(asks); continue
        if k == "s": sessions_screen(); getkey(600); continue
        if k == "o":
            ref = re.search(r"#(\d+)", a["ref"])
            if ref: subprocess.run(["open", f"https://github.com/keyorixhq/keyorix/issues/{ref.group(1)}"])
            else: msg = "No GitHub number on this question."
            continue
        note, choice = "", None
        if k in ("\n", "\r"): choice = a["rec"]
        elif k in a["opts"]: choice = k
        elif k == "p": choice = "park"
        elif k == "n":
            sys.stdout.write(f"\n  Option ({'/'.join(a['opts'])}, Enter = {a['rec']}): "); sys.stdout.flush()
            c = sys.stdin.readline().strip() or a["rec"]
            if c not in a["opts"] and c != "park": msg = f"'{c}' is not an option; nothing saved."; continue
            sys.stdout.write("  Note (one line, Enter when done): "); sys.stdout.flush()
            choice, note = c, sys.stdin.readline().strip()
        else:
            msg = f"Key '{k}' does nothing here. Use {'/'.join(a['opts'])}, Enter, n, p, arrows, o, s or q."; continue
        answer(a, choice, note)
        n = cmd_route()
        label = "parked" if choice == "park" else f"answered '{choice}'"
        msg = f"Saved: question {i+1} {label}. Sent to {', '.join(a['askers'][:3])} (if running) and MERGE-MASTER."

def cmd_list(_):
    for a in sorted(load(OPEN), key=lambda a: (not a["blocking"], a["asked_at"])):
        print(f"- {'BLOCKING ' if a['blocking'] else ''}{a['id']} {a['ref']}: {a['q']} (rec {a['rec']}: {a['opts'].get(a['rec'],'')}) [{', '.join(a['askers'])}, {a['asked_at']}]")

def gc_obsolete():
    """2026-11-07: an ask about a PR/issue of this repo that is now CLOSED/MERGED has no subject left: move it to answered/ as
    'obsolete' (not routed to anyone). Only runs from `route` (refill, every 5 min); any gh failure leaves the ask open."""
    n = 0
    for a in load(OPEN):
        ref = a.get("ref", "")
        if "/" in ref.split("#")[0]: continue            # another repo, or a file path
        nums = re.findall(r"(?<![\w/])#(\d+)", ref)
        if not nums: continue
        closed = True
        for num in nums:
            st = None
            for kind in ("pr", "issue"):
                r = subprocess.run(["gh", kind, "view", num, "-R", "keyorixhq/keyorix", "--json", "state", "-q", ".state"], capture_output=True, text=True)
                if r.returncode == 0: st = r.stdout.strip(); break
            if st not in ("CLOSED", "MERGED"): closed = False; break
        if closed:
            a.update(answer="obsolete", note="subject closed or merged", answered_at=now(), routed=now(), routed_to=[])
            save(DONE, a); os.remove(f"{OPEN}/{a['id']}.json")
            with open(f"{A}/answers.log", "a") as f: f.write(f"{now()} {a['id']} -> obsolete (subject {ref} closed) | not routed\n")
            n += 1
    return n

def _close_obsolete(a, why, dry):
    print(("DRY " if dry else "") + f"obsolete {a['id']}: {why}")
    if dry: return
    a.update(answer="obsolete", note=why, answered_at=now(), routed=now(), routed_to=[])
    save(DONE, a); os.remove(f"{OPEN}/{a['id']}.json")
    with open(f"{A}/answers.log", "a") as f: f.write(f"{now()} {a['id']} -> obsolete ({why}) | not routed\n")

def _gh_ok(pr, head):
    """2026-11-22 ASK-GC-APPROVED-1: the gate ask is answered once github-approved.txt holds this exact head (kx-gh-approve wrote it); the dashboard kept showing #N/#N/#N after the OK"""
    try:
        for l in open(f"{A}/../../github-approved.txt"):
            f = l.split()
            if len(f) >= 2 and f[0] == str(pr) and head and f[1] == head: return True
    except Exception: pass
    return False

def _approved_at(pr, head):
    """2026-11-16: a review (ledger row in review-outcomes.tsv) APPROVEd this exact head"""
    ok = False; last = ""
    try:
        for l in open(f"{A}/../review-outcomes.tsv"):
            f = l.rstrip("\n").split("\t")
            if len(f) >= 5 and f[0].startswith(f"REVIEW-{pr}-DEEP-") and f[2] == head[:9] and f[3] == "DONE": ok = f[4].upper() == "APPROVE"; last = f[0]
    except Exception: return True
    # OPUSFINAL-1: a Sonnet APPROVE on security-critical paths is not an approval yet (the Opus confirmation is owed) -> no gate question to the admin
    if ok and not os.path.exists(f"{A}/../OPUSFINAL-OFF"):
        try:
            if last in {l.strip() for l in open(f"{A}/../sec-sonnet-tags.txt")}: return False
        except Exception: pass
    return ok

def gc_stale(dry=False):
    """2026-11-11: two more kinds of ask whose subject is gone although the PR is still open.
    (1) stuck-watch asks are keyed '<pr>-stuck-<head>': when the PR head moved on, the question was about code that no longer exists
        (stuck-watch asks again by itself if the new head is also stuck for hours).
    (2) vuln asks ('vuln-<GO id>-nofix', 'govulncheck-...'): when MAIN-RED-VULN.txt no longer holds that GO id the main-red is cleared.
    Any gh failure leaves the ask open."""
    n = 0
    vuln = ""
    try: vuln = open(f"{A}/../MAIN-RED-VULN.txt").read().upper()
    except Exception: pass
    for a in load(OPEN):
        aid = a.get("id", "")
        m = re.match(r"^(\d+)-stuck-([0-9a-f]{7,40})$", aid)
        if m:
            r = subprocess.run(["gh", "pr", "view", m.group(1), "-R", "keyorixhq/keyorix", "--json", "headRefOid", "-q", ".headRefOid"], capture_output=True, text=True)
            head = r.stdout.strip()
            if r.returncode == 0 and head and not head.startswith(m.group(2)):
                _close_obsolete(a, f"stuck-watch ask was about head {m.group(2)[:9]}, PR head is now {head[:9]}", dry); n += 1
            continue
        m = re.match(r"^gate-(\d+)-([0-9a-f]{7,40})$", aid)
        if m:   # 2026-11-16: a gate ask is about one head; obsolete when the PR is closed, the head moved, or the verdict for that head is a DEFECT (a fixer owns it)
            r = subprocess.run(["gh", "pr", "view", m.group(1), "-R", "keyorixhq/keyorix", "--json", "state,headRefOid"], capture_output=True, text=True)
            try: info = json.loads(r.stdout)
            except Exception: info = None
            if r.returncode == 0 and info:
                head = info.get("headRefOid", "")
                defect = False
                try:
                    for l in open(f"{A}/../decline-class.txt"):
                        f = l.split()
                        if len(f) >= 3 and f[0] == m.group(1) and head and head.startswith(f[1][:8]) and f[2] == "DEFECT": defect = True
                except Exception: pass
                if info.get("state") != "OPEN": _close_obsolete(a, f"PR #{m.group(1)} is {info.get('state')}", dry); n += 1
                elif head and not head.startswith(m.group(2)): _close_obsolete(a, f"gate ask was about head {m.group(2)[:9]}, PR head is now {head[:9]}", dry); n += 1
                elif _gh_ok(m.group(1), head): _close_obsolete(a, f"admin already approved head {m.group(2)[:9]} (github-approved.txt): nothing left to ask", dry); n += 1
                elif not _approved_at(m.group(1), head): _close_obsolete(a, f"no review APPROVEd head {m.group(2)[:9]} yet: the owner's OK is asked after the review, not before", dry); n += 1
                elif defect: _close_obsolete(a, f"verdict for head {m.group(2)[:9]} is a DEFECT: a fixer owns it, no gate question", dry); n += 1
            continue
        g = re.search(r"(GO-\d{4}-\d+)", aid.upper())
        if g and ("vuln" in aid or "govulncheck" in aid) and os.path.exists(f"{A}/../MAIN-RED-VULN.cleared") and g.group(1) not in vuln:
            _close_obsolete(a, f"{g.group(1)} no longer in MAIN-RED-VULN.txt (main-red cleared)", dry); n += 1
    return n

def cmd_answer(o):
    """2026-11-11 `kx answer`: answer an open ask by id or by PR (#N). Default choice = the recommendation. Exit 2 if ambiguous or none."""
    t = o.target.lstrip("#")
    asks = [a for a in load(OPEN) if a.get("id") == o.target or (t.isdigit() and (a.get("ref") or "").strip("#") == t)]
    if not asks: print(f"no open ask for '{o.target}'"); sys.exit(2)
    if len(asks) > 1: print("ambiguous, use the ask id:\n" + "\n".join("  " + a["id"] for a in asks)); sys.exit(2)
    a = asks[0]; ch = (o.choice or a.get("rec") or "").lower()
    _ci = {k.lower(): k for k in a.get("opts", {})}   # 2026-11-24: an option containing capitals (e.g. a session tag) could never match the lower-cased answer
    if ch in _ci: ch = _ci[ch]
    if ch not in a.get("opts", {}): print(f"{a['id']}: choice must be one of {', '.join(a.get('opts', {}))}"); sys.exit(2)
    note = " ".join(o.note) or "owner chose " + ch + (" (recommendation)" if ch == a.get("rec") else "") + " via kx answer"
    answer(a, ch, note)
    with open(f"{A}/answers.log", "a") as f: f.write(f"{now()} {a['id']} -> {ch} {note}\n")
    print(f"{a['id']}: answered {ch}: {a['opts'][ch]}"); cmd_route()

ap = argparse.ArgumentParser(); sp = ap.add_subparsers(dest="c", required=True)
x = sp.add_parser("ask"); x.add_argument("--id", required=True); x.add_argument("--q", required=True)
x.add_argument("--opt", action="append"); x.add_argument("--rec", default=""); x.add_argument("--ref")
x.add_argument("--why"); x.add_argument("--product", choices=["keyorix", "dashdiag"]); x.add_argument("--blocking", action="store_true"); x.add_argument("--from", dest="frm")
for c in ("ui", "list", "route"): sp.add_parser(c)
ansp = sp.add_parser("answer"); ansp.add_argument("target"); ansp.add_argument("choice", nargs="?"); ansp.add_argument("note", nargs="*")
gcp = sp.add_parser("gc"); gcp.add_argument("--dry", action="store_true")
o = ap.parse_args()
{"ask": cmd_ask, "ui": cmd_ui, "list": cmd_list, "route": lambda o: (auto_answer(), gc_obsolete(), gc_stale(), cmd_route())[3], "answer": cmd_answer, "gc": lambda o: print(f"gc: {gc_obsolete() if not o.dry else 0} closed-subject, {gc_stale(o.dry)} stale")}[o.c](o)
