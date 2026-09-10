#!/usr/bin/env python3
"""Summarize the newest tracking trace: timeline frames drawn, presented, stalls."""
import csv, glob, os, sys
f = sys.argv[1] if len(sys.argv) > 1 else max(glob.glob(os.path.expanduser("~/Library/Logs/DuofyTracking/*.csv")), key=os.path.getmtime)
rows = list(csv.DictReader(open(f)))
tf = [r for r in rows if r["event"] == "timeline_frame"]
pres = sorted(float(r["b"]) for r in rows if r["event"] == "presented" and r["b"] and float(r["b"]) > 0)
notshown = sum(1 for r in rows if r["event"] == "presented" and (not r["b"] or float(r["b"]) <= 0))
drop = sum(r["event"] == "render_dropped" for r in rows)
if not tf: sys.exit("no timeline frames")
fr = [int(float(r["a"])) for r in tf]
t = [float(r["time"]) for r in tf]
g = sorted((t[i] - t[i - 1]) * 1000 for i in range(1, len(t)))
pg = sorted((pres[i] - pres[i - 1]) * 1000 for i in range(1, len(pres)))
q = lambda a, p: a[min(int(len(a) * p), len(a) - 1)] if a else 0
print(f"timeline N={int(float(tf[0]['b']))}  drawn={len(tf)}  on screen={len(pres)}  never shown={notshown}  dropped before GPU={drop}")
print(f"ms between drawn frames   p50 {q(g,.5):.1f}  p95 {q(g,.95):.1f}  max {g[-1]:.1f}")
print(f"ms between presented      p50 {q(pg,.5):.1f}  p95 {q(pg,.95):.1f}  max {pg[-1] if pg else 0:.1f}")
print(f"stalls >20ms drawn: {sum(x > 20 for x in g)}   presented: {sum(x > 20 for x in pg)}")

# A presented gap is a real stall only if new frames were drawn during it (the playhead was moving).
drawn_t = t
stalls = []
for i in range(1, len(pres)):
    a, b = pres[i - 1], pres[i]
    if (b - a) * 1000 > 20 and any(a < x < b - 0.004 for x in drawn_t):
        stalls.append(round((b - a) * 1000, 1))
print(f"real stalls (drawn but not shown for >20ms): {len(stalls)}  {stalls[:15]}")
