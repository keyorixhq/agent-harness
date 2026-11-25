#!/usr/bin/env python3
"""report.py [hours=24] -- RESMON-1 report from resmon.db: who writes/reads where, throttling, per-session picture, collector coverage."""
import sqlite3, sys, os, datetime as dt
DB = os.environ.get("RESMON_DB", os.path.expanduser("~/proj/hw/resmon/resmon.db"))
H = float(sys.argv[1]) if len(sys.argv) > 1 else 24
c = sqlite3.connect(DB); cut = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=H)).strftime("%Y-%m-%dT%H:%M")
mb = lambda b: f"{(b or 0)/1048576:,.0f} MB"
print(f"RESMON report, last {H:g} h (db {DB})")
r = c.execute("SELECT MIN(ts),MAX(ts),COUNT(*) FROM sys WHERE ts>=?", (cut,)).fetchone(); print(f"sys samples: {r[2]}  {r[0]} .. {r[1]}")
print("\n== thermal pressure"); tot = c.execute("SELECT COUNT(*) FROM sys WHERE ts>=?", (cut,)).fetchone()[0] or 1
for t, n in c.execute("SELECT thermal,COUNT(*) FROM sys WHERE ts>=? GROUP BY 1 ORDER BY 2 DESC", (cut,)): print(f"  {t or '?':<10} {100*n/tot:5.1f}%")
print("\n== CPU power by live sessions (median mW)")
for s, n, m in c.execute("SELECT sessions,COUNT(*),AVG(cpu_mw) FROM sys WHERE ts>=? AND sessions IS NOT NULL GROUP BY 1 ORDER BY 1", (cut,)): print(f"  {s:>2} sessions  n={n:<6} avg {m or 0:,.0f} mW")
print("\n== DISK TRAFFIC BY DEVICE (which volume: SSD vs RAM disk), MB read / written")
dm = dict(c.execute("SELECT dev, mount FROM devmap WHERE ts=(SELECT MAX(ts) FROM devmap)").fetchall())
for d, rd, wr in c.execute("SELECT dev, SUM(CASE WHEN op IN('rd','pgin','rd-meta') THEN bytes END), SUM(CASE WHEN op IN('wr','pgout','wr-meta') THEN bytes END) FROM diskio WHERE minute>=? GROUP BY 1 ORDER BY 3 DESC", (cut,)):
    mnt = dm.get(d) or ("(whole disk / container: " + (", ".join(sorted({m for k, m in dm.items() if k.startswith(d + 's')}))[:30] or "?") + ")" if d else "")
    print(f"  {d or '?':<12} {mnt[:28]:<28} read {mb(rd):>10}   written {mb(wr):>10}")
print("\n== WRITERS (disk, physical: write + page-out), top 15 processes")
for p, b, e in c.execute("SELECT proc,SUM(bytes),SUM(events) FROM diskio WHERE minute>=? AND op IN('wr','pgout','wr-meta') GROUP BY 1 ORDER BY 2 DESC LIMIT 15", (cut,)): print(f"  {p[:32]:<32} {mb(b):>12}  {e:>9} events")
print("\n== WRITE DIRECTORIES, top 15")
for d, b, e in c.execute("SELECT dir,SUM(bytes),SUM(events) FROM diskio WHERE minute>=? AND op IN('wr','pgout','wr-meta') GROUP BY 1 ORDER BY 2 DESC LIMIT 15", (cut,)): print(f"  {d[:70]:<70} {mb(b):>12}")
print("\n== READ DIRECTORIES (read + page-in), top 15")
for d, b, e in c.execute("SELECT dir,SUM(bytes),SUM(events) FROM diskio WHERE minute>=? AND op IN('rd','pgin','rd-meta') GROUP BY 1 ORDER BY 2 DESC LIMIT 15", (cut,)): print(f"  {d[:70]:<70} {mb(b):>12}")
print("\n== BY SESSION TAG (written to disk)")
for t, b in c.execute("SELECT tag,SUM(bytes) FROM diskio WHERE minute>=? AND tag<>'' AND op IN('wr','pgout','wr-meta') GROUP BY 1 ORDER BY 2 DESC LIMIT 10", (cut,)): print(f"  {t[:40]:<40} {mb(b):>12}")
print("\n== WRITE VOLUME BY HOUR (MB)")
for h, b in c.execute("SELECT substr(minute,1,13),SUM(bytes) FROM diskio WHERE minute>=? AND op IN('wr','pgout','wr-meta') GROUP BY 1 ORDER BY 1", (cut,)): print(f"  {h}  {(b or 0)/1048576:8,.0f}  " + "#" * int((b or 0) / 1048576 / 200))
print("\n== COVERAGE: diskio bytes written vs kernel per-process counters (powermetrics tasks, top-25 sampled every 60 s)")
a = c.execute("SELECT SUM(bytes) FROM diskio WHERE minute>=? AND op IN('wr','pgout')", (cut,)).fetchone()[0] or 0
k = c.execute("SELECT SUM(wr_bps*60) FROM proc WHERE ts>=?", (cut,)).fetchone()[0] or 0
print(f"  fs_usage physical writes {mb(a)}   kernel counters (60 s x rate, top-25 only) {mb(k)}   ratio {a/k if k else 0:.2f}  (about 1 = the capture sees what the kernel counts)")
print("\n== COLLECTOR COST (avg %CPU of one core / avg RSS MB)")
for w, p, r_ in c.execute("SELECT who,AVG(cpu_pct),AVG(rss_mb) FROM cost WHERE ts>=? GROUP BY 1", (cut,)): print(f"  {w:<32} {p:5.1f}%  {r_:7.0f} MB")
