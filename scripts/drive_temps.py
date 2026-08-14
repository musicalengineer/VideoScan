#!/usr/bin/env python3
"""Drive temperature monitor with green/yellow/red status.

Reads what it can without elevation and reports the rest as unavailable
rather than failing. Exit code is the worst status seen, so launchd or a
menu-bar plugin can act on it:

    0 = all green      1 = something yellow      2 = something red

Usage:
    drive_temps.py              pretty, colored
    drive_temps.py --json       machine-readable
    drive_temps.py --menubar    SwiftBar/xbar single-line + detail
    drive_temps.py --notify     post a macOS notification if yellow/red

Thresholds differ by medium. Spinning disks care about a much lower
ceiling than NVMe: drive-reliability studies put HDD failure rates up
sharply past ~45-50 C, while an SN850X does not throttle until ~80 C.
"""
import json
import os
import re
import subprocess
import sys

SMARTCTL = "/opt/homebrew/bin/smartctl"

# (label, device, smartctl extra args, medium)
DEVICES = [
    ("Internal SSD",  "/dev/disk0",  [],             "ssd"),
    ("PRO-G40 NVMe",  "/dev/disk7",  [],             "ssd"),
    ("LaCie d2 (HDD)", "/dev/disk24", ["-d", "sat"], "hdd"),
]

# medium -> (yellow_at, red_at) in Celsius
THRESHOLDS = {
    "ssd": (55, 70),
    "hdd": (42, 48),
}

GREEN, YELLOW, RED = "green", "yellow", "red"
RANK = {GREEN: 0, YELLOW: 1, RED: 2}
DOT = {GREEN: "🟢", YELLOW: "🟡", RED: "🔴"}
ANSI = {GREEN: "\033[32m", YELLOW: "\033[33m", RED: "\033[31m"}
RESET = "\033[0m"


def classify(temp, medium):
    warn, crit = THRESHOLDS[medium]
    if temp >= crit:
        return RED
    if temp >= warn:
        return YELLOW
    return GREEN


def read_temp(device, extra):
    """Return integer Celsius, or None if unreadable."""
    if not os.path.exists(SMARTCTL):
        return None
    try:
        out = subprocess.run([SMARTCTL, "-A", *extra, device],
                             capture_output=True, text=True, timeout=20).stdout
    except (subprocess.SubprocessError, OSError):
        return None
    # NVMe style: "Temperature:  37 Celsius"
    m = re.search(r"^Temperature:\s+(\d+)\s+Celsius", out, re.M)
    if m:
        return int(m.group(1))
    # ATA style: attribute 194 Temperature_Celsius ... RAW_VALUE
    m = re.search(r"^19[04]\s+\S*Temperature\S*.*?(\d+)(?:\s|$)", out, re.M)
    if m:
        return int(m.group(1))
    return None


def thermal_pressure():
    """CPU speed limit as a proxy for how hard the room is pushing back."""
    try:
        out = subprocess.run(["pmset", "-g", "therm"],
                             capture_output=True, text=True, timeout=10).stdout
        m = re.search(r"CPU_Speed_Limit\s*=\s*(\d+)", out)
        if m:
            return int(m.group(1))
    except (subprocess.SubprocessError, OSError):
        pass
    return None


def collect():
    results = []
    for label, dev, extra, medium in DEVICES:
        if not os.path.exists(dev):
            results.append({"label": label, "device": dev, "temp": None,
                            "status": None, "note": "not attached"})
            continue
        t = read_temp(dev, extra)
        if t is None:
            results.append({"label": label, "device": dev, "temp": None,
                            "status": None, "note": "needs sudo or no SMART"})
            continue
        results.append({"label": label, "device": dev, "temp": t,
                        "medium": medium, "status": classify(t, medium),
                        "note": ""})
    return results


def worst(results):
    seen = [r["status"] for r in results if r["status"]]
    return max(seen, key=lambda s: RANK[s]) if seen else GREEN


def main():
    results = collect()
    overall = worst(results)
    limit = thermal_pressure()

    if "--json" in sys.argv:
        print(json.dumps({"overall": overall, "cpuSpeedLimit": limit,
                          "drives": results}, indent=2))
    elif "--menubar" in sys.argv:
        hot = [r for r in results if r["status"] in (YELLOW, RED)]
        if hot:
            print(f"{DOT[overall]} {max(r['temp'] for r in hot)}°")
        else:
            print(DOT[GREEN])
        print("---")
        for r in results:
            if r["temp"] is None:
                print(f"{r['label']}: — ({r['note']})")
            else:
                print(f"{DOT[r['status']]} {r['label']}: {r['temp']}°C")
        if limit is not None and limit < 100:
            print(f"⚠️ CPU throttled to {limit}%")
    else:
        print(f"{'DRIVE':<18} {'TEMP':>6}  STATUS")
        print("-" * 40)
        for r in results:
            if r["temp"] is None:
                print(f"{r['label']:<18} {'—':>6}  ({r['note']})")
            else:
                c = ANSI[r["status"]]
                print(f"{r['label']:<18} {r['temp']:>4}°C  "
                      f"{c}{DOT[r['status']]} {r['status'].upper()}{RESET}")
        print("-" * 40)
        print(f"{'OVERALL':<18} {'':>6}  {ANSI[overall]}{DOT[overall]} "
              f"{overall.upper()}{RESET}")
        if limit is not None:
            note = "" if limit == 100 else "   <-- thermal throttling"
            print(f"CPU speed limit: {limit}%{note}")

    if "--notify" in sys.argv and overall != GREEN:
        hot = [r for r in results if r["status"] in (YELLOW, RED)]
        detail = ", ".join(f"{r['label']} {r['temp']}°C" for r in hot)
        subprocess.run([
            "osascript", "-e",
            f'display notification "{detail}" with title "Drive temperature: {overall.upper()}"'
        ], check=False)

    sys.exit(RANK[overall])


if __name__ == "__main__":
    main()
