#!/usr/bin/env python3
"""nightly_rota.py — where a Mac stands on the 2 AM nightly rotation (GH #360).

The rotation itself is scripts/nightly_rota.json (one file; the publisher reads it
too). This is the shell scripts' way in:

  python3 scripts/nightly_rota.py slot RicksM4   ->  "on 2 0"        (hour minute)
  python3 scripts/nightly_rota.py slot RicksM1   ->  "off travel laptop, …"
  python3 scripts/nightly_rota.py slot Other     ->  "unknown"
  python3 scripts/nightly_rota.py label RicksM5  ->  "M5"
  python3 scripts/nightly_rota.py analysis RicksM4 ->  "on 4 30"       (the Swift 6 analysis lane's slot)
  python3 scripts/nightly_rota.py gauntlet RicksM4 ->  "yes"           (the full testbed: suite + gauntlet)
  python3 scripts/nightly_rota.py machine RicksM4  ->  "m4"            (the gauntlet's machine label on the page)

Exit 0 always for `slot` / `label` / `analysis` / `gauntlet` / `machine` (the answer is in stdout); a
broken rota file reads as "unknown" for every host, which makes the installer
refuse and the guard run as before — never silently drop a Mac that should run.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROTA = Path(__file__).resolve().parent / "nightly_rota.json"
LABEL_RE = re.compile(r"^[A-Z][A-Za-z0-9]{0,5}$")


def label(host: str) -> str:
    """"RicksM4" -> "M4" — the same rule as tools/publish_metrics.host_label."""
    lab = re.sub(r"^ricks", "", (host or "").strip(), flags=re.IGNORECASE)
    return lab if LABEL_RE.match(lab) else ""


def slot(host: str, rota_path: Path = ROTA, key: str = "on") -> str:
    """`key` is the map holding the time: "on" (the test nightly) or
    "analysis" (the Swift 6 analysis lane). "off" always wins."""
    try:
        rota = json.loads(rota_path.read_text())
    except (OSError, ValueError):
        return "unknown"
    lab = label(host)
    on = rota.get(key) or {}
    off = rota.get("off") or {}
    if lab and lab in off:
        return f"off {off[lab]}"
    if lab and lab in on:
        m = re.match(r"^(\d{1,2}):(\d{2})$", str(on[lab]))
        if not m:
            return "unknown"
        return f"on {int(m.group(1))} {int(m.group(2))}"
    return "unknown"


def gauntlet(host: str, rota_path: Path = ROTA) -> str:
    """"yes" when this Mac's run is the full testbed (suite + gauntlet,
    scripts/nightly_gauntlet.sh). Anything unreadable is "no": the plain
    nightly still runs, so a broken file never drops a Mac's tests."""
    try:
        rota = json.loads(rota_path.read_text())
    except (OSError, ValueError):
        return "no"
    lab = label(host)
    listed = rota.get("gauntlet") or []
    off = rota.get("off") or {}
    return "yes" if lab and isinstance(listed, list) and lab in listed and lab not in off else "no"


# The gauntlet runner's machine labels (scripts/run_gauntlet.sh --machine
# m4|m5|m1; the published row's "machine" field). One table for
# nightly_gauntlet.sh (which label to run as) and nightly_guarded.sh (which
# rows count as this Mac's gauntlet). "" = no label: the runner's default
# (m4) applies and the guard can match no gauntlet row.
MACHINES = {"M4": "m4", "Ultra": "m5", "M1": "m1"}


def machine(host: str) -> str:
    return MACHINES.get(label(host), "")


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[0] not in ("slot", "label", "analysis", "gauntlet", "machine"):
        print(__doc__, file=sys.stderr)
        return 2
    if argv[0] == "label":
        print(label(argv[1]))
    elif argv[0] == "gauntlet":
        print(gauntlet(argv[1]))
    elif argv[0] == "machine":
        print(machine(argv[1]))
    else:
        print(slot(argv[1], key="on" if argv[0] == "slot" else "analysis"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
