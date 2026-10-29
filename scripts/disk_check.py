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
  repair   One named external container, by volume name or diskN. Unmounts,
           verifies, and runs repairVolume only if that verify found
           problems: a clean disk is never written. Rick's decision each time,
           never scheduled. Refuses the boot disk (repair that from Recovery).

Each container ends in one named outcome: ok, repaired, problemsFound,
notChecked (busy; remounted), leftUnmounted (remount failed: the log says
which container and the command to mount it). Only ok and repaired are success.

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
    external: bool = False   # positive evidence only: Internal == False and a non-image bus
    disk_image: bool = False
    system: bool = False     # any volume has an APFS role (System, Data, Preboot...): a boot container

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
        infos = [store_info.get(s, {}) for s in stores]
        buses = [i.get("BusProtocol") for i in infos]
        out.append(Container(
            ref=c["ContainerReference"],
            store=stores[0],
            volumes=[v.get("Name", v["DeviceIdentifier"]) for v in c.get("Volumes", [])],
            # Every physical store must prove itself external; one doubtful store protects the container.
            external=all(i.get("Internal") is False and bool(b) and b != "Disk Image"
                         for i, b in zip(infos, buses)),
            disk_image=any(b == "Disk Image" for b in buses),
            system=any(v.get("Roles") for v in c.get("Volumes", [])),
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
    if target:
        # Resolve the name against EVERY container before eligibility, so a
        # name shared with a protected container can never fall through to
        # the one eligible match.
        matches = [c for c in containers if target in (c.ref, *c.volumes)]
        if len(matches) > 1:
            return [], [f"{target!r} is ambiguous: {'; '.join(c.label for c in matches)}"]
        containers = matches
    picked, skipped = [], []
    for c in containers:
        if c.disk_image:
            skipped.append(f"{c.label}: disk image")
        elif mode != "live" and c.system:
            skipped.append(f"{c.label}: holds system-role volumes (a boot container); "
                           f"live verify only, repair from Recovery")
        elif mode != "live" and not c.external:
            skipped.append(f"{c.label}: not proven external (internal disk, or no diskutil info); "
                           f"live verify only, repair from Recovery")
        else:
            picked.append(c)
    return picked, skipped


def verdict(proc: subprocess.CompletedProcess[str], ref: str) -> bool:
    """Clean only if: exit 0, the CHECKED container's own OK line, and no line
    saying anything could not be verified or reporting an error. A volume's
    OK line never stands in for the container's."""
    text = proc.stdout + proc.stderr
    lines = [ln.strip().lower() for ln in text.splitlines()]
    container_ok = f"the container /dev/r{ref} {OK_MARK}".lower() in lines
    doubt = any("could not be verified" in ln or ln.startswith("error") for ln in lines)
    return proc.returncode == 0 and container_ok and not doubt


def log(line: str) -> None:
    stamp = _dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(line, flush=True)
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a") as f:
        f.write(f"{stamp} {line}\n")


def notify(message: str) -> None:
    # The message travels as argv, never spliced into the script: volume names may hold quotes.
    run(["osascript",
         "-e", "on run argv",
         "-e", 'display notification (item 1 of argv) with title "Disk check"',
         "-e", "end run",
         message])


def videoscan_running() -> bool:
    """Fail closed: only pgrep's "no match" (exit 1) proves VideoScan is not running."""
    return run(["pgrep", "-x", "VideoScan"]).returncode != 1


# Outcomes. Only "ok" and "repaired" count as success.
#   ok             verified clean (repair mode: clean, so nothing was written)
#   repaired       verify found problems, repairVolume then succeeded
#   problemsFound  verify (or repair) did not come back clean
#   notChecked     could not unmount (busy); remounted, nothing checked
#   leftUnmounted  remount failed: the container is NOT mounted now
SUCCESS = ("ok", "repaired")


def _verify_then_maybe_repair(c: Container, mode: str) -> tuple[str, str]:
    p = run(["diskutil", "verifyVolume", c.ref])
    text = p.stdout + p.stderr
    if verdict(p, c.ref):
        return "ok", text
    if mode != "repair":
        return "problemsFound", text
    r = run(["diskutil", "repairVolume", c.ref])
    text += r.stdout + r.stderr
    # "repaired" is proven by a fresh verify, not by repairVolume's own words.
    v = run(["diskutil", "verifyVolume", c.ref])
    text += "--- verify after repair ---\n" + v.stdout + v.stderr
    return ("repaired" if r.returncode == 0 and verdict(v, c.ref) else "problemsFound"), text


def check_one(c: Container, mode: str) -> tuple[str, str]:
    if mode == "live":
        return _verify_then_maybe_repair(c, mode)

    # offline / repair: unmount without force; busy means refuse, not guess.
    # unmountDisk can fail part-way (one volume busy, its sibling already
    # unmounted), and anything after it can raise (Ctrl-C included), so the
    # remount attempt sits in `finally`. Like a C++ destructor (RAII guard).
    outcome, text = "notChecked", ""
    try:
        u = run(["diskutil", "unmountDisk", c.ref])
        if u.returncode == 0:
            outcome, text = _verify_then_maybe_repair(c, mode)
        else:
            text = (f"NOT CHECKED: could not unmount {c.label} (busy?): {u.stdout}{u.stderr}"
                    f"  Who holds it: lsof +f -- /Volumes/<name>\n")
    except Exception as e:
        outcome, text = "notChecked", text + f"NOT CHECKED: {c.label}: {e!r}\n"
    finally:
        try:
            m = run(["diskutil", "mountDisk", c.ref])
            mounted, mtext = m.returncode == 0, m.stdout + m.stderr
        except Exception as e:
            mounted, mtext = False, repr(e)
        if not mounted:
            warning = (f"!! {c.label} is NOT MOUNTED (check outcome was {outcome}). "
                       f"Mount it: diskutil mountDisk {c.ref}")
            outcome = "leftUnmounted"   # set before anything that can raise
            text += f"{warning}\n{mtext}"
            try:
                log(warning)    # logged here too: on Ctrl-C nothing after this runs
            except Exception:
                print(warning, file=sys.stderr, flush=True)
    return outcome, text


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
        print("VideoScan is running (or pgrep could not tell); quit it first "
              "(offline/repair unmount volumes).", file=sys.stderr)
        return 2

    try:
        containers = discover()
    except Exception as e:
        log(f"OUTCOME disk_check mode={mode} error: could not list containers: {e!r}")
        notify("Could not list disks; nothing was checked.")
        return 1
    picked, skipped = select(containers, mode, a.repair)
    if mode == "repair" and len(picked) != 1:
        for s in skipped:
            print(f"  {s}", file=sys.stderr)
        print(f"--repair {a.repair!r} matched {len(picked)} external containers; name exactly one.", file=sys.stderr)
        return 2

    log(f"START disk_check mode={mode} containers={len(picked)}")
    for s in skipped:
        log(f"  skip {s}")
    if not picked:
        log(f"OUTCOME disk_check mode={mode} error: no containers to check; nothing was checked")
        notify("No disks were checked.")
        return 1
    failed = []
    for c in picked:
        try:
            outcome, output = check_one(c, mode)
        except Exception as e:      # live verify raised; offline already handled inside
            outcome, output = "notChecked", f"NOT CHECKED: {c.label}: {e!r}\n"
        ok = outcome in SUCCESS
        if not a.quiet or not ok:
            print(output, flush=True)
        log(f"  {outcome:<13} {c.label}")
        if not ok:
            failed.append(f"{c.label}: {outcome}")
            with LOG.open("a") as f:
                f.write(output)
    log(f"OUTCOME disk_check mode={mode} ok={len(picked) - len(failed)} failed={len(failed)}"
        + (f" [{'; '.join(failed)}]" if failed else ""))
    if failed:
        notify(f"{len(failed)} container(s) failed: {'; '.join(failed)}. See {LOG}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
