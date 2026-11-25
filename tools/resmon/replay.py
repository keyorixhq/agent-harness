#!/usr/bin/env python3
"""replay.py CAPTURE.txt DB -- load a saved `fs_usage -f diskio` capture through the same parser/aggregator into a fresh DB (for tests and demos)."""
import sys, os, sqlite3, collections, resmon
cap, dbp = sys.argv[1], sys.argv[2]
if os.path.exists(dbp): os.remove(dbp)
resmon.CON = sqlite3.connect(dbp); resmon.CON.executescript(resmon.SCHEMA)
agg = collections.Counter(); ev = collections.Counter(); n = 0
for l in open(cap, errors="replace"):
    pr = resmon.parse_diskio(l)
    if not pr: continue
    op, b, path, proc, dev = pr; d, tag = resmon.norm_dir(path) if path else ("(no path)", "")
    cls = ("rd" if op.startswith("Rd") else "wr" if op.startswith("Wr") else "pgin" if op == "PgIn" else "pgout") + ("-meta" if op.endswith("Meta") else "")
    k = (proc, tag, cls, d, dev.replace("/dev/", "")); agg[k] += b; ev[k] += 1; n += 1
resmon.CON.executemany("INSERT INTO diskio VALUES(?,?,?,?,?,?,?,?)", [(resmon.dt.datetime.now(resmon.dt.timezone.utc).strftime("%Y-%m-%dT%H:%MZ"), k[0], k[1], k[2], k[3], ev[k], agg[k], k[4]) for k in agg])
resmon.CON.executemany("INSERT INTO devmap VALUES(?,?,?)", [(resmon.now_iso(), "disk5s1", "/Volumes/RAMDISK"), (resmon.now_iso(), "disk3s5", "/System/Volumes/Data")])
resmon.CON.commit(); print("replayed", n, "events,", len(agg), "keys")
