#!/usr/bin/env python3
"""Summarize monotonic Dusk trace events. Ages are host pipeline timings, not optical lid latency."""
import argparse
import csv
import json
import statistics
from pathlib import Path


def stats(values):
    values = sorted(v for v in values if v >= 0)
    if not values:
        return None
    def pct(p):
        return values[round((len(values) - 1) * p)]
    return {"count": len(values), "p50": pct(.50), "p95": pct(.95), "max": values[-1]}


def analyze(path):
    rows = []
    for row in csv.DictReader(path.open()):
        row = {k: (float(v) if v else None) if k != "event" else v for k, v in row.items()}
        rows.append(row)
    groups = {}
    for row in rows:
        groups.setdefault(row["event"], []).append(row)
    sensors = groups.get("sensor", [])
    draws = {r["id"]: r for r in groups.get("draw", [])}
    commits = {r["id"]: r for r in groups.get("commit", [])}
    report = {"file": str(path), "events": {k: len(v) for k, v in groups.items()}}
    report["sensor_read_ms"] = stats([(r["e"] - r["time"]) * 1000 for r in sensors])
    report["sensor_to_main_ms"] = stats([(r["time"] - r["a"]) * 1000 for r in groups.get("sensor_main", [])])
    report["capture_to_main_ms"] = stats([(r["time"] - r["a"]) * 1000 for r in groups.get("capture_main", [])])
    report["drawable_wait_ms"] = stats([(r["b"] - r["time"]) * 1000 for r in draws.values()])
    report["gpu_ms"] = stats([(r["c"] - r["b"]) * 1000 for r in groups.get("gpu", [])])
    report["draw_to_present_ms"] = stats([(r["b"] - draws[r["id"]]["time"]) * 1000
                                           for r in groups.get("presented", []) if r["id"] in draws and r["b"] > 0])
    report["commit_to_present_ms"] = stats([(r["b"] - commits[r["id"]]["time"]) * 1000
                                             for r in groups.get("presented", []) if r["id"] in commits and r["b"] > 0])
    report["render_vs_target_degrees"] = stats([abs(r["a"] - r["b"]) for r in groups.get("filter", [])])
    report["coarse_fine_disagreement_degrees"] = stats([abs(r["a"] - r["b"]) for r in sensors])
    for key, col in [("coarse", "a"), ("fine", "b")]:
        times = [b["time"] for a, b in zip(sensors, sensors[1:]) if a[col] != b[col]]
        report[key + "_change_interval_ms"] = stats([(b - a) * 1000 for a, b in zip(times, times[1:])])
    states = sorted(groups.get("controller_state", []), key=lambda r: r["time"])
    mappings = {r["id"]: (r["a"], r["b"]) for r in groups.get("controller_mapping", [])}
    unexplained = []
    for previous, current in zip(states, states[1:]):
        if (previous["d"] == current["d"] == 1 and previous["a"] == current["a"]
                and mappings.get(previous["id"]) == mappings.get(current["id"])
                and (previous["b"], previous["c"]) != (current["b"], current["c"])):
            unexplained.append(current["time"])
    report["pose_changes_without_angle_or_reference_change"] = unexplained
    if states:
        last = states[-1]
        report["latest_status"] = dict(zip(
            ["angle", "tilt", "progress", "visible", "pending_capture", "enabled", "paused", "live_preview"],
            [last[k] for k in "abcdefgh"]))
    report["limitations"] = "Host timestamps; HID reports expose no hardware acquisition timestamp. Value-change intervals include stationary noise. Optical motion-to-photon latency is unmeasured."
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", nargs="?", type=Path)
    args = parser.parse_args()
    path = args.trace or max((Path.home() / "Library/Logs/DuskTracking").glob("*.csv"), key=lambda p: p.stat().st_mtime)
    print(json.dumps(analyze(path), indent=2))
