#!/usr/bin/env python3
"""Check the file system on every APFS container on this Mac.

    python3 scripts/disk_check.py                 # live verify, every container
    python3 scripts/disk_check.py --offline       # externals: unmount, verify, remount
    sudo python3 scripts/disk_check.py --repair FamilyArchive
                                                  # one external container: unmount, repair, remount

Modes, weakest to strongest:

  live     `diskutil verifyVolume <container>` = `fsck_apfs -n`: read-only,
           no unmount, no sudo. Safe while you work; this is the weekly job.
  offline  Externals only. Unmount the container (never forced: a busy volume
           is skipped and reported), verify it, remount it. A quieter check
           than live because nothing can write mid-check. Run after a reboot,
           before starting work, when you want the stronger answer.
  repair   One named external container, by volume name or diskN. Writes
           file-system metadata, so it is Rick's decision each time and is
           never scheduled. Refuses the boot disk (repair that from Recovery).

Disk images (Xcode's Metal toolchain cryptex and the like) are skipped.
Offline and repair refuse while VideoScan is running.

Every run appends START / per-container lines / OUTCOME to
~/Library/Logs/VideoScan/disk_check.log, posts a notification on failure,
and exits 0 only when every checked container is OK.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import os
import plistlib
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

LOG = Path.home() / "Library/Logs/VideoScan/disk_check.log"
OK_MARK = "appears to be OK"


@dataclass
class Container:
    ref: str                 # disk13
    store: str               # disk12s2
    volumes: list[str] = field(default_factory=list)
    internal: bool = False
    disk_image: bool = False

    @property
    def label(self) -> str:
        return f"{self.ref} ({', '.join(self.volumes) or 'no volumes'})"


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True)


def parse_containers(apfs_list: dict, store_info: dict[str, dict]) -> list[Container]:
    """Containers from `diskutil apfs list -plist`, tagged from `diskutil info -plist <store>`."""
    out = []
    for c in apfs_list.get("Containers", []):
        stores = [s["DeviceIdentifier"] for s in c.get("PhysicalStores", [])]
        if not stores:
            continue
        info = store_info.get(stores[0], {})
        out.append(Container(
            ref=c["ContainerReference"],
            store=stores[0],
            volumes=[v.get("Name", v["DeviceIdentifier"]) for v in c.get("Volumes", [])],
            internal=bool(info.get("Internal", False)),
            disk_image=info.get("BusProtocol") == "Disk Image",
        ))
    return out


def discover() -> list[Container]:
    apfs = plistlib.loads(subprocess.run(
        ["diskutil", "apfs", "list", "-plist"], capture_output=True, check=True).stdout)
    infos = {}
    for c in apfs.get("Containers", []):
        for s in c.get("PhysicalStores", []):
            r = subprocess.run(["diskutil", "info", "-plist", s["DeviceIdentifier"]], capture_output=True)
            infos[s["DeviceIdentifier"]] = plistlib.loads(r.stdout) if r.returncode == 0 else {}
    return parse_containers(apfs, infos)


def select(containers: list[Container], mode: str, target: str | None) -> tuple[list[Container], list[str]]:
    """What this mode checks, and why anything was left out (said, never silent)."""
    picked, skipped = [], []
    for c in containers:
        if c.disk_image:
            skipped.append(f"{c.label}: disk image")
        elif mode != "live" and c.internal:
            skipped.append(f"{c.label}: internal disk is live-verify only (repair from Recovery)")
        elif target and target not in (c.ref, *c.volumes):
            continue
        else:
            picked.append(c)
    return picked, skipped


def verdict(proc: subprocess.CompletedProcess[str]) -> bool:
    return proc.returncode == 0 and OK_MARK in proc.stdout


def log(line: str) -> None:
    stamp = _dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(line, flush=True)
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a") as f:
        f.write(f"{stamp} {line}\n")


def notify(message: str) -> None:
    run(["osascript", "-e", f'display notification "{message}" with title "Disk check"'])


def videoscan_running() -> bool:
    return run(["pgrep", "-x", "VideoScan"]).returncode == 0


def check_one(c: Container, mode: str) -> tuple[bool, str]:
    verb = "repairVolume" if mode == "repair" else "verifyVolume"
    if mode == "live":
        p = run(["diskutil", verb, c.ref])
        return verdict(p), p.stdout + p.stderr

    # offline / repair: unmount without force; busy means refuse, not guess.
    u = run(["diskutil", "unmountDisk", c.ref])
    if u.returncode != 0:
        return False, f"NOT CHECKED: could not unmount (busy?): {u.stdout}{u.stderr}" \
                      f"  See who holds it: lsof +f -- /Volumes/<name>\n"
    try:
        p = run(["diskutil", verb, c.ref])
        return verdict(p), p.stdout + p.stderr
    finally:
        m = run(["diskutil", "mountDisk", c.ref])
        if m.returncode != 0:
            log(f"  !! {c.label}: REMOUNT FAILED — run: diskutil mountDisk {c.ref}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--offline", action="store_true", help="externals: unmount, verify, remount")
    g.add_argument("--repair", metavar="NAME", help="repair ONE external container (volume name or diskN); needs sudo")
    ap.add_argument("--quiet", action="store_true", help="no per-container fsck output on stdout")
    a = ap.parse_args(argv)
    mode = "repair" if a.repair else "offline" if a.offline else "live"

    if mode == "repair" and os.geteuid() != 0:
        print("--repair writes file-system metadata and needs sudo.", file=sys.stderr)
        return 2
    if mode != "live" and videoscan_running():
        print("VideoScan is running; quit it first (offline/repair unmount volumes).", file=sys.stderr)
        return 2

    picked, skipped = select(discover(), mode, a.repair)
    if mode == "repair" and len(picked) != 1:
        print(f"--repair {a.repair!r} matched {len(picked)} external containers; name exactly one.", file=sys.stderr)
        return 2

    log(f"START disk_check mode={mode} containers={len(picked)}")
    for s in skipped:
        log(f"  skip {s}")
    failed = []
    for c in picked:
        ok, output = check_one(c, mode)
        if not a.quiet or not ok:
            print(output, flush=True)
        log(f"  {'OK  ' if ok else 'FAIL'} {c.label}")
        if not ok:
            failed.append(c.label)
            with LOG.open("a") as f:
                f.write(output)
    log(f"OUTCOME disk_check mode={mode} ok={len(picked) - len(failed)} failed={len(failed)}"
        + (f" [{'; '.join(failed)}]" if failed else ""))
    if failed:
        notify(f"{len(failed)} container(s) failed: {'; '.join(failed)}. See {LOG}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
