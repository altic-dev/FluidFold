#!/usr/bin/env python3
"""Count drawable-wait stalls in the closing phase (first 1 s after the overlay appears) of the newest trace."""
import csv, glob, os, sys
f = sys.argv[1] if len(sys.argv) > 1 else max(glob.glob(os.path.expanduser("~/Library/Logs/DuskTracking/*.csv")), key=os.path.getmtime)
rows = list(csv.DictReader(open(f)))
show = [float(r["time"]) for r in rows if r["event"] == "overlay_show"][0]
d = [r for r in rows if r["event"] == "draw" and show <= float(r["time"]) <= show + 1.0]
w = [(float(r["b"]) - float(r["time"])) * 1000 for r in d]
print(f"closing phase: {len(d)} draws, drawable waits >10ms: {sum(x > 10 for x in w)}, total waited {sum(w):.0f} ms, max {max(w):.0f} ms")
