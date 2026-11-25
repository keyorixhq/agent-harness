#!/usr/bin/env python3
"""resmon.py -- RESMON-1 (2026-11-24): resource monitor for the harness Mac. Run as root (launchd daemon, see install.sh).
Four collectors, one SQLite DB (~/proj/hw/resmon/resmon.db, WAL, 30-day retention):
  sys     every 10 s   thermal pressure, CPU/GPU power (powermetrics), load, swap, memory pressure, disk MB/s and net MB/s totals
  proc    every 60 s   per process: CPU ms/s, bytes read/written per s (powermetrics tasks, no gaps: kernel counters), tag of the session
  net     every 60 s   per process cumulative network bytes -> deltas (nettop)
  diskio  continuous   `fs_usage -f diskio` aggregated per minute by (process, op, directory): who reads/writes WHERE and how often
Every collector logs its own cost; fs_usage is restarted hourly (its memory grows) and when it reports dropped events. Paths are normalised
(home -> ~, tag/go-build/hex ids masked, depth limited): file names and contents are never stored. Off: `launchctl bootout system/com.keyorix.resmon`."""
import os, re, sys, time, sqlite3, subprocess, threading, signal, collections, datetime as dt

HOME = os.environ.get("RESMON_HOME", os.path.expanduser("~"))
DB = os.environ.get("RESMON_DB", f"{HOME}/proj/hw/resmon/resmon.db")
LOG = os.environ.get("RESMON_LOG", f"{HOME}/proj/hw/resmon/resmon.log")
KEEP_DAYS = int(os.environ.get("RESMON_KEEP_DAYS", "30"))
STOP = threading.Event()

def log(msg):
    try:
        with open(LOG, "a") as f: f.write(f"{dt.datetime.now(dt.timezone.utc).strftime('%FT%TZ')} resmon: {msg}\n")
    except Exception: pass

SCHEMA = """
CREATE TABLE IF NOT EXISTS sys(ts TEXT, thermal TEXT, cpu_mw REAL, gpu_mw REAL, load1 REAL, swap_mb REAL, mem_free_pct REAL, disk_rd_mbs REAL, disk_wr_mbs REAL, net_in_mbs REAL, net_out_mbs REAL, sessions INT);
CREATE TABLE IF NOT EXISTS proc(ts TEXT, name TEXT, pid INT, tag TEXT, cpu_ms_s REAL, rd_bps REAL, wr_bps REAL);
CREATE TABLE IF NOT EXISTS net(ts TEXT, name TEXT, in_b INT, out_b INT);
CREATE TABLE IF NOT EXISTS diskio(minute TEXT, proc TEXT, tag TEXT, op TEXT, dir TEXT, events INT, bytes INT, dev TEXT);
CREATE TABLE IF NOT EXISTS devmap(ts TEXT, dev TEXT, mount TEXT);
CREATE TABLE IF NOT EXISTS cost(ts TEXT, who TEXT, cpu_pct REAL, rss_mb REAL, note TEXT);
CREATE INDEX IF NOT EXISTS i_sys ON sys(ts); CREATE INDEX IF NOT EXISTS i_proc ON proc(ts); CREATE INDEX IF NOT EXISTS i_dio ON diskio(minute);
"""
_dblock = threading.Lock()
def db():
    c = sqlite3.connect(DB, timeout=30, check_same_thread=False); c.execute("PRAGMA journal_mode=WAL"); c.execute("PRAGMA synchronous=NORMAL"); return c
CON = None
def put(sql, rows):
    if not rows: return
    with _dblock: CON.executemany(sql, rows); CON.commit()
def now_iso(): return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# ---------- path normalisation ----------
_HEX = re.compile(r"[0-9a-fA-F]{8,}")
def norm_dir(path):
    """directory of the file, normalised and depth-limited; returns (dir, tag)"""
    p = path.strip()
    if not p.startswith("/"): p = "/" + p
    p = p[len("/System/Volumes/Data"):] if p.startswith("/System/Volumes/Data/") else p
    p = p.replace(HOME, "~", 1) if p.startswith(HOME) else p
    p = re.sub(r"^/private(?=/(tmp|var|etc))", "", p)
    tag = ""
    m = re.match(r"(?:~/proj/work|/Volumes/RAMDISK/gotmp)/([A-Za-z0-9._-]+)", p)
    if m: tag = m.group(1)
    d = p.rsplit("/", 1)[0] if "/" in p[1:] else p
    parts = [x for x in d.split("/") if x]
    out = []
    for x in parts[:7]:
        x = re.sub(r"^(go-build|go-link-|gc-)\d+.*", r"\1*", x)
        x = _HEX.sub("#", x)
        x = re.sub(r"\d{5,}", "#", x)
        out.append(x)
    s = "/" + "/".join(out) if not out or out[0] != "~" else "/".join(out)
    if tag: s = s.replace(tag, "<TAG>", 1)
    return s[:120], tag

# ---------- diskio (continuous fs_usage, aggregated per minute) ----------
_LINE = re.compile(r"^\S+\s+(RdData|WrData|RdMeta|WrMeta|PgIn|PgOut)\[[^\]]*\]\s+D=0x[0-9a-f]+\s+B=(0x[0-9a-f]+)\s+(/dev/\S+)\s*(.*?)\s+\d+\.\d+\s+W\s+(\S+)\s*$")
_LINE2 = re.compile(r"^\S+\s+(RdData|WrData|RdMeta|WrMeta|PgIn|PgOut)\[[^\]]*\]\s+D=0x[0-9a-f]+\s+B=(0x[0-9a-f]+)\s+(/dev/\S+)")
def parse_diskio(line):
    """-> (op, bytes, path, process) or None. Lines without a process name (device-level metadata) are kept as '(unattributed)'."""
    m = _LINE.match(line)
    if m: return m.group(1), int(m.group(2), 16), m.group(4), m.group(5).rsplit(".", 1)[0], m.group(3)
    m = _LINE2.match(line)
    if m: return m.group(1), int(m.group(2), 16), "", "(unattributed)", m.group(3)
    return None

def diskio_loop():
    while not STOP.is_set():
        agg = collections.Counter(); ev = collections.Counter(); minute = None; started = time.time(); dropped = 0
        p = subprocess.Popen(["fs_usage", "-w", "-f", "diskio"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors="replace", bufsize=1)
        log(f"diskio: fs_usage started pid {p.pid}")
        def err():
            nonlocal dropped
            for l in p.stderr:
                if "drop" in l.lower(): dropped += 1
        threading.Thread(target=err, daemon=True).start()
        def flush(minute):
            rows = [(minute, k[0], k[1], k[2], k[3], ev[k], agg[k], k[4]) for k in agg]
            put("INSERT INTO diskio VALUES(?,?,?,?,?,?,?,?)", rows); agg.clear(); ev.clear()
        for line in p.stdout:
            if STOP.is_set(): break
            pr = parse_diskio(line)
            if pr:
                op, b, path, proc, dev = pr
                d, tag = norm_dir(path) if path else ("(no path)", "")
                cls = ("rd" if op.startswith("Rd") else "wr" if op.startswith("Wr") else "pgin" if op == "PgIn" else "pgout") + ("-meta" if op.endswith("Meta") else "")
                k = (proc, tag, cls, d, dev.replace('/dev/', ''))
                agg[k] += b; ev[k] += 1
            mn = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
            if minute is None: minute = mn
            if mn != minute: flush(minute); minute = mn
            if time.time() - started > 300: break           # restart every 5 min: fs_usage RSS grows ~1.3 GB/h (measured 2026-11-24: 1.3 GB after 1 h), so a short life keeps it near 100 MB
        if minute: flush(minute)
        try: p.terminate(); p.wait(5)
        except Exception: pass
        if dropped: log(f"diskio: fs_usage reported {dropped} drop warning(s) in the last run")
        if not STOP.is_set(): time.sleep(1)

# ---------- sys + proc (one long powermetrics stream: thermal, cpu_power, tasks with per-process IO) ----------
def parse_tasks(block):
    rows = []; hdr = None
    for l in block.splitlines():
        if l.startswith("Name") and "Bytes Read" in l: hdr = True; continue
        if hdr and l.strip():
            if l.startswith("ALL_TASKS") or l.startswith("DEAD_TASKS"): continue
            m = re.match(r"^(.*?)\s{2,}(-?\d+)\s+([\d.]+)\s+([\d.]+)\s+[\d.]+\s+[\d.]+\s+[\d.]+\s+[\d.]+\s+([\d.]*)\s+([\d.]*)\s", l)
            if m: rows.append((m.group(1).strip(), int(m.group(2)), float(m.group(3)), float(m.group(5) or 0), float(m.group(6) or 0)))
        elif hdr and not l.strip(): break
    return rows

def sysnums():
    out = {}
    try:
        la = os.getloadavg(); out["load1"] = la[0]
        sw = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True).stdout
        m = re.search(r"used = ([\d.]+)M", sw); out["swap_mb"] = float(m.group(1)) if m else None
        mp = subprocess.run(["memory_pressure"], capture_output=True, text=True, timeout=10).stdout
        m = re.search(r"free percentage: (\d+)%", mp); out["mem_free_pct"] = float(m.group(1)) if m else None
        out["sessions"] = len(subprocess.run(["pgrep", "-f", "run-session"], capture_output=True, text=True).stdout.split())
    except Exception: pass
    return out

def tag_of_pid(pid, cache={}):
    if pid in cache and time.time() - cache[pid][1] < 600: return cache[pid][0]
    t = ""
    try:
        o = subprocess.run(["lsof", "-a", "-d", "cwd", "-p", str(pid), "-Fn"], capture_output=True, text=True, timeout=5).stdout
        m = re.search(r"/proj/work/([A-Za-z0-9._-]+)", o); t = m.group(1) if m else ""
    except Exception: pass
    cache[pid] = (t, time.time()); return t

def pm_loop():
    last_proc = 0
    while not STOP.is_set():
        p = subprocess.Popen(["powermetrics", "--samplers", "thermal,cpu_power,gpu_power,tasks", "--show-process-io", "-i", "10000"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, errors="replace")
        buf = []; log(f"sys/proc: powermetrics started pid {p.pid}")
        try:
            for line in p.stdout:
                if STOP.is_set(): break
                if line.startswith("*** Sampled system activity") and buf:
                    block = "".join(buf); buf = []
                    ts = now_iso()
                    th = re.search(r"Current pressure level: (\w+)", block); cp = re.search(r"^CPU Power: (\d+) mW", block, re.M); gp = re.search(r"^GPU Power: (\d+) mW", block, re.M)
                    s = sysnums()
                    put("INSERT INTO sys(ts,thermal,cpu_mw,gpu_mw,load1,swap_mb,mem_free_pct,sessions) VALUES(?,?,?,?,?,?,?,?)",
                        [(ts, th.group(1) if th else None, float(cp.group(1)) if cp else None, float(gp.group(1)) if gp else None, s.get("load1"), s.get("swap_mb"), s.get("mem_free_pct"), s.get("sessions"))])
                    if time.time() - last_proc >= 60:
                        last_proc = time.time()
                        rows = parse_tasks(block)
                        top = sorted(rows, key=lambda r: (r[3] + r[4], r[2]), reverse=True)[:25]
                        put("INSERT INTO proc VALUES(?,?,?,?,?,?,?)", [(ts, r[0], r[1], tag_of_pid(r[1]) if (r[3] + r[4] > 1e5 or r[2] > 200) else "", r[2], r[3], r[4]) for r in top])
                buf.append(line)
        finally:
            try: p.terminate(); p.wait(5)
            except Exception: pass
        if not STOP.is_set(): time.sleep(2)

# ---------- net (nettop deltas) ----------
def net_loop():
    prev = {}
    while not STOP.is_set():
        try:
            o = subprocess.run(["nettop", "-P", "-L", "1", "-J", "bytes_in,bytes_out"], capture_output=True, text=True, timeout=30).stdout
            ts = now_iso(); rows = []; cur = {}
            for l in o.splitlines()[1:]:
                f = l.rstrip(",").split(",")
                if len(f) >= 3 and f[1].isdigit():
                    cur[f[0]] = (int(f[1]), int(f[2]))
            for k, (i, o_) in cur.items():
                pi, po = prev.get(k, (i, o_))
                if i - pi > 0 or o_ - po > 0: rows.append((ts, k, max(0, i - pi), max(0, o_ - po)))
            prev = cur; put("INSERT INTO net VALUES(?,?,?,?)", rows)
        except Exception as e: log(f"net: {e}")
        STOP.wait(60)

# ---------- own cost + retention ----------
def housekeeping():
    while not STOP.is_set():
        try:
            o = subprocess.run(["ps", "-axo", "pid=,%cpu=,rss=,args="], capture_output=True, text=True).stdout
            rows = []
            for l in o.splitlines():
                m = re.match(r"\s*(\d+)\s+([\d.]+)\s+(\d+)\s+(.*)", l)
                if m and re.search(r"(fs_usage -w -f diskio|powermetrics --samplers thermal,cpu_power,gpu_power,tasks|resmon\.py)", m.group(4)):
                    rows.append((now_iso(), m.group(4)[:30], float(m.group(2)), int(m.group(3)) / 1024.0, ""))
            put("INSERT INTO cost VALUES(?,?,?,?,?)", rows)
            if dt.datetime.now().minute % 30 == 0:   # which /dev/diskNsM is the SSD and which is the RAM disk: df, refreshed twice an hour
                dm = [(now_iso(), l.split()[0].replace('/dev/', ''), l.split()[-1]) for l in subprocess.run(["df", "-h"], capture_output=True, text=True).stdout.splitlines()[1:] if l.startswith('/dev/')]
                put("INSERT INTO devmap VALUES(?,?,?)", dm)
            if dt.datetime.now().minute == 5:
                cut = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=KEEP_DAYS)).strftime("%Y-%m-%dT%H:%M")
                with _dblock:
                    for t, c in (("sys", "ts"), ("proc", "ts"), ("net", "ts"), ("diskio", "minute"), ("cost", "ts")): CON.execute(f"DELETE FROM {t} WHERE {c} < ?", (cut,))
                    CON.commit()
        except Exception as e: log(f"housekeeping: {e}")
        STOP.wait(60)

def main():
    global CON
    os.makedirs(os.path.dirname(DB), exist_ok=True); CON = db(); CON.executescript(SCHEMA)
    if "--selftest" in sys.argv: return selftest()
    signal.signal(signal.SIGTERM, lambda *a: STOP.set()); signal.signal(signal.SIGINT, lambda *a: STOP.set())
    log(f"start, keep {KEEP_DAYS} d, db {DB}")
    ts = [threading.Thread(target=f, daemon=True) for f in (diskio_loop, pm_loop, net_loop, housekeeping)]
    for t in ts: t.start()
    while not STOP.is_set(): STOP.wait(5)
    log("stop")

def selftest():
    ok = True
    d, tag = norm_dir(HOME + "/proj/work/MQ-X-1/keyorix/internal/core/x.go")
    assert tag == "MQ-X-1" and d == "~/proj/work/<TAG>/keyorix/internal/core", (d, tag)
    d, tag = norm_dir("/Volumes/RAMDISK/gotmp/TAG-1/go-build2691842140/b1052/guards.test")
    assert tag == "TAG-1" and d.startswith("/Volumes/RAMDISK/gotmp/<TAG>/go-build*"), (d, tag)
    d, tag = norm_dir("private/tmp/wt-canary/internal/encryption/encryption_test.go")
    assert d == "/tmp/wt-canary/internal/encryption", d
    m = _LINE.match("12:31:14.450655  WrData[A]       D=0x038173de  B=0x100000  /dev/disk3s5  private/tmp/resmon-probe  0.000278 W dd.460434382")
    assert m and m.group(5) == "dd.460434382" and int(m.group(2), 16) == 1048576, m
    assert parse_diskio("12:31:12.640234    RdMeta[ST1]     D=0x0017150a  B=0x1000   /dev/disk3                                                          0.000045 W kernel_task.2127")[3] == "kernel_task"
    assert parse_diskio("12:36:45.898263    RdMeta[ST1]     D=0x00017d84  B=0x1000   /dev/disk3  /dev/disk3     ")[3] == "(unattributed)"
    print("resmon selftest ok"); return 0

if __name__ == "__main__": sys.exit(main() or 0)
