# P0 — VideoScan processes wedge unkillably at exit (Sandbox.kext rename lock)

**Status: OPEN.** Root cause not yet proven. Written 2026-09-14 ~18:10 ET so the
investigation survives a reboot of the M4.

**Impact:** Rick cancelled a live demo for his uncle on 2026-09-14 — the app
would neither launch nor quit properly. Xcode could not quit. Two reboots so far
(2026-09-13 ~13:15, and one pending).

---

## Symptom

VideoScan processes enter state `?E` (exiting) with zero resident memory and the
command name in parentheses — `(VideoScan)`. They **cannot be killed**; `kill -9`
does nothing because the thread is stuck inside the kernel. Only a reboot clears
them. While present, a later VideoScan process *can* block at exit behind the
lock they still hold.

Detector: `scripts/check_wedged_processes.py` (exit 1 when any are present).

---

## PROVEN (two independent machines, from spindumps)

Evidence preserved in `~/Library/Logs/VideoScan/incidents/2026-09-14-sandbox-wedge/`
(raw + decoded; decode with `spindump -i raw.txt -o decoded.txt`).

### M4 (Mac16,9, kernel t6041, macOS 26.6.2 / 25G83)

Four wedged processes, started Sep 13 20:34 → Sep 14 02:28 (Rick's spot-test
session plus Claude's overnight agent runs):

| PID | started | what it was |
|---|---|---|
| 35869 | Sep 13 20:34:54 | Rick's Release app |
| 51245 | Sep 13 21:47:19 | test host — **holds the lock** |
| 59499 | Sep 13 23:00:55 | test host |
| 71905 | Sep 14 02:27:59 | test host |

Five threads across those four processes are blocked in:

```
hook_vnode_notify_will_rename_swap + 140 (Sandbox + 105200)
  IORWLockWrite + 180
    (suspended, blocked by krwlock for writing owned by VideoScan [51245] thread 0xc0b24)
```

`51245` thread `0xc0b24` **holds** that rwlock and is itself asleep in
`lck_mtx_sleep`, last ran 70,044 s before the dump. Its process is a zombie, so
the lock is never released. The lock is shared across processes of the same app.

### M1 (MacBookPro18,2, kernel t6000, same macOS build, uptime 26 days)

One wedged process, PID 81216, started Sep 14 09:59:45 during the nightly test
lane. Same structure, but entirely **self**-deadlocked — 4 threads:

| thread | state |
|---|---|
| `0x13bd0a1` | **holds** the rwlock, asleep in `lck_mtx_sleep` |
| `0x13bc619` | asleep in `lck_mtx_sleep`, same shape |
| `0x13bc61a` | blocked in the rename hook, wants the rwlock |
| `0x13bd0a2` | blocked in the rename hook, wants the rwlock |

**The M1 dump carries the key clue** — its own header notes:

```
Workqueue exceeded cooperative thread limit for 1 sample
  (more swift tasks runnable than allowed to run concurrently)
Workqueue exceeded active constrained thread limit for 1 sample
```

Swift's cooperative thread pool was saturated at the moment of deadlock.

---

## DISPROVEN (do not re-litigate without new evidence)

1. **"`renamex_np` is the trigger because it is new since 2026-09-12"** (commit
   `bd05b08a`, the People UUID-folder migration, which introduced both
   `renamex_np` and `clonefile` — genuinely their first appearance in six months
   of the project). A harness doing **3,200 concurrent directory renames across 8
   threads**, both `rename(2)` and `renamex_np(RENAME_EXCL)`, under
   `sandbox-exec`, completed in ~1 s with zero wedges on the M1.
   (`wedge_repro.py`)
2. **"Renames in flight while the process exits."** 40 rounds per arm of abrupt
   `_exit()` mid-rename: zero wedges. (`wedge_repro2.py`)
3. **"Swift cooperative-pool saturation alone, in any sandboxed binary."** A
   Swift harness flooding the pool with blocking FS work then exiting: 12 rounds,
   zero wedges. (`PoolWedge.swift`)
4. **"The machine is globally poisoned."** False — ordinary and `sandbox-exec`
   processes perform `rename`/`renamex_np`/`clonefile` instantly while four
   VideoScan processes are wedged, and a fresh Debug app launched AND quit
   cleanly on 2026-09-14 ~17:46. The four are corpses, not an active trap.

Likely reason 1–3 all failed: the lock appears to be taken for **container /
sandbox-extension bookkeeping**, which a real App-Sandboxed bundle (and an XCTest
host) has and a `sandbox-exec` binary does not.

---

## CURRENT HYPOTHESIS

Blocking filesystem work performed on **Swift's cooperative thread pool**
saturates it (one thread per core). One task acquires the Sandbox kext's rename
rwlock and then waits on something that needs another task to make progress;
that task can never be scheduled because every pool thread is blocked. Circular
wait → the process can never exit.

Fits all the evidence: the spindump's own workqueue note; four of five wedges
being XCTest hosts (a full battery is the one workload that floods the pool with
concurrent file-touching tasks); rarity in ordinary app use; and why it appeared
now rather than in March — the suite has grown, not the syscalls.

## EXPERIMENT IN FLIGHT (started 2026-09-14 ~18:00)

`ab_wedge.sh` on **M1 and M5**, both on commit `eb2eede1`, arms in opposite
order to cancel ordering effects:

- arm A: full `VideoScanTests` battery, `-parallel-testing-enabled YES` ×2
- arm B: same battery, `-parallel-testing-enabled NO` ×2

Wedge count is taken before and after each run. Logs: `/tmp/ab-wedge.log` and
`/tmp/ab-<arm>-<run>.log` on each machine (those machines are NOT being
rebooted). **Read: do wedges appear only in the parallel arm?**

- Yes → hypothesis holds. Immediate mitigation: bound test parallelism. Real
  fix: move blocking file I/O off the cooperative executor.
- No → hypothesis dies; we still gain a measured baseline on two machines.

## CONTRIBUTING FACTOR (ours, regardless of root cause)

On the night of 2026-09-13 an agent ran the **full 7,661-test battery twice**,
against the standing policy of focused suites during rapid dev. That is what
turned a rare bug into four wedges in one night and cost the demo. Agents are
restricted to focused suites.

## NEXT STEPS

1. Read the A/B result on M1 and M5.
2. If confirmed: bound test parallelism now; then audit blocking FS work inside
   async contexts (`POIStorage`, catalog/store writers, `ArchiveAngelPlan` saves)
   and move it to a dedicated executor.
3. Re-run the A/B as the fix's oracle — a fix nobody can measure is a theory.
4. Report to Apple with both spindumps: a kext rwlock held by a sleeping thread
   of a zombie process is their bug regardless of what provokes it.

## OPEN, UNRELATED, FOUND ALONG THE WAY

- Two VideoScan processes on the M1 stuck in state `T` (SIGSTOP'd) since Sep 7 —
  suspended and never resumed. Our pause machinery sends SIGSTOP
  (`JobPauseCoordinator`). Worth a look.
- The detached `--find-tag` daemon and `videoscan-preview-sweep --watch` survive
  app quit by design, orphaned to launchd, and were observed at ~95–99% CPU each
  after the GUI exited.
