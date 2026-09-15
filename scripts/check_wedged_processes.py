#!/usr/bin/env python3
"""Report VideoScan processes stuck in exit (state ?E) — the Sandbox.kext
rename-hook wedge (first seen 2026-09-13, cost a demo on 2026-09-14).

Such a process cannot be killed; only a reboot clears it, and while one is
present a later VideoScan process CAN block at exit behind the lock it still
holds. This exists so the rate is measured rather than discovered.

Exit codes: 0 none found, 1 one or more (so a nightly step can gate on it).
"""
import re, subprocess, sys

def wedged():
    out = subprocess.run(["ps", "-Ao", "pid,stat,lstart,etime,comm"],
                         capture_output=True, text=True).stdout.splitlines()
    rows = []
    for line in out[1:]:
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        pid, rest = parts
        m = re.match(r"(\S+)\s+(.{24})\s+(\S+)\s+(.*)", rest)
        if not m:
            continue
        stat, started, etime, comm = m.groups()
        if "E" in stat and "VideoScan" in comm:
            rows.append((pid, stat, started.strip(), etime, comm.strip()))
    return rows

rows = wedged()
if not rows:
    print("No wedged VideoScan processes.")
    sys.exit(0)
print(f"WEDGED VideoScan processes: {len(rows)} (unkillable — only a reboot clears these)")
for pid, stat, started, etime, comm in rows:
    print(f"  pid {pid:<8} state={stat:<4} stuck {etime:>12}  since {started}  {comm}")
print("\nCapture evidence BEFORE rebooting:  sudo spindump <pid> 5 -file ~/Desktop/wedge.txt")
sys.exit(1)
