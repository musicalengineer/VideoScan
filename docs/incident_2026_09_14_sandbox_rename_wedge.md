# P0 — VideoScan processes wedge unkillably at exit (Sandbox.kext rename lock)

**Status: ROOT CAUSE PROVEN AND FIXED, 2026-09-14 ~19:30 ET.**
Fix on `fix/sandbox-rename-swap-wedge` (`6c4623ca`).

**Impact:** Rick cancelled a live demo for his uncle on 2026-09-14 — the app
would neither launch nor quit properly. Xcode could not quit. Three reboots.

---

## Symptom

VideoScan processes enter state `?E` (exiting) with zero resident memory and the
command name in parentheses — `(VideoScan)`. They **cannot be killed**; `kill -9`
does nothing because the thread is stuck inside the kernel. Only a reboot clears
them.

Two further consequences, both observed:

- A later process of the same app can block at exit behind the lock a corpse
  still holds (M4: four corpses chained to one owner).
- **Sometimes the app can no longer be launched.** On the M1, four consecutive
  `xcodebuild` runs died instantly with
  `IDELaunchServicesLauncher.m:418 … Assertion failed: childPID > 0` while a
  corpse was present. **But this is NOT simply "a corpse blocks relaunch"** —
  on the M5, a test host launched and ran 60 tests normally with a corpse
  present. A corpse is not sufficient to cause it, and the M1 failure's real
  cause is **not established**. Do not assume this explains the demo's
  "would not launch" symptom; that remains unexplained.

Detector: `scripts/check_wedged_processes.py` (exit 1 when any are present).

---

## ROOT CAUSE

`FileManager.replaceItemAt(_:withItemAt:)` compiles to
`renameatx_np(… RENAME_SWAP)` on APFS. `Sandbox.kext` hooks that syscall in
`hook_vnode_notify_will_rename_swap`, where it takes an `IORWLock`
**exclusively and keeps holding it** across the VFS rename. The holding thread
then sleeps in `vfs_subr.c` waiting on a vnode whose iocount belongs to a second
thread — which is itself parked in the same hook waiting for that rwlock.

**ABBA deadlock, inside the kernel, unrecoverable from user space.** The threads
never return, so the process can never finish exiting, so the rwlock is never
released.

### The stacks, symbolicated

Both spindumps were symbolicated against the on-disk kernels in
`/System/Library/Kernels/` by nearest preceding exported symbol
(`sym.py` in the evidence directory). The structure is **identical** on
M4/t6041 and M1/t6000:

| role | frames |
|---|---|
| blocked threads | `renameat_internal` (`_futimes+8472`) → mac rename hook dispatch (`_mac_vnode_label_set+3432`) → `hook_vnode_notify_will_rename_swap` → `lck_rw_lock_exclusive` |
| **lock owner** | `renameat_internal` (`_futimes+8136` — same function, 336 bytes later, i.e. *past* the hook and still holding) → `_vnode_removefsref+356` → `_sleep+296` → `lck_mtx_sleep` |

The `_futimes+N` / `_vnode_removefsref+N` names are the nearest *exported*
symbols in `vfs_syscalls.c` and `vfs_subr.c`; the real functions are static.
What matters is that the owner is in the same syscall as the blocked threads,
past the hook, asleep on a vnode.

Raw evidence in `~/Library/Logs/VideoScan/incidents/2026-09-14-sandbox-wedge/`
(decode a raw dump with `spindump -i raw.txt -o decoded.txt`).

### Reproduced from scratch

`wedge_repro3.py` and `wedge_min.py` in the evidence directory. Plain,
unsandboxed **Python** — no VideoScan code, no app bundle, no sandbox,
M1 internal SSD:

| workload | result |
|---|---|
| 2 threads, `RENAME_SWAP`, **same** path pair | **WEDGED after 26 ops** |
| 8 threads, `RENAME_SWAP`, disjoint pairs, one dir | 40,000 ops, 4.9 s, clean |
| 8 threads, `rename(2)`, **same** destination | 32,000 ops, 12.7 s, clean |
| 8 threads, `renamex_np(RENAME_EXCL)`, same dir | clean |

**The trigger is exactly two concurrent rename-SWAPS onto one destination.**
Disjoint paths are safe. Plain `rename(2)` is safe.

### Every other way we publish a file was then checked too

Each converted call site still writes its temp with `Data.write(options: .atomic)`
first, so if Foundation's atomic writers also swapped, converting the publish
step would have fixed nothing. They do not. `AtomicProbe.swift` and
`StringProbe.swift` in the evidence directory, 4 threads onto ONE destination:

| writer | ops | result |
|---|---|---|
| `Data.write(to:options:.atomic)` | 12,000 | clean, 2.0 s |
| `String.write(to:atomically:)` | 8,000 | clean, 1.0 s |
| `NSDictionary.write(to:atomically:)` | 8,000 | clean, 1.0 s |
| the `AtomicFilePublish` shape (unique temp + `rename(2)`) | 12,000 | clean, 2.0 s |

So all 56 `.atomic` writes in production are safe, and the only source of
`RENAME_SWAP` in this project was `FileManager.replaceItemAt`.

### Confidence, stated honestly

High on the mechanism: the deadlock is **deterministic**, not a rare race —
contended `RENAME_SWAP` wedges within ~26 ops every time, so there is no
long tail of unlucky timings to worry about. High on our code being clean:
an exhaustive grep over app, VideoScanCore, swift_cli and tests finds no
`replaceItemAt` and no `RENAME_SWAP`, and the six months of clean history
before 09-09 says our own call sites were the whole source.

The residual risk that inspection cannot close is a **system framework** we
call in-process emitting a swap on a path two of our threads contend. The
oracle for that is empirical and still owed: run the full battery — the
workload that produced four wedges on 09-13 and one on the M5 on 09-14 — on
the fixed build, on a rebooted machine, and count wedges.

### Not volume specific

The lock is taken in the MAC layer, above the filesystem — the syscall never
reaches APFS. Observed on an internal SSD (M1 home), a RAM disk
(`/Volumes/XcodeRAM`) and `~/Library/Caches`. **The Pegasus R4 / FamilyArchive
is not implicated.**

---

## WHY NOW, AND NOT IN THE PREVIOUS SIX MONTHS

`replaceItemAt` had exactly one call site until July — `PreviewDiskCache`,
serialised behind its own lock. Between 2026-09-09 and 2026-09-13 **four more
stores adopted it**: `ArchiveAngelPlan` (09-09), `ArchiveAngelEvidenceStore`
(09-09), `IgnoredContentStore` (09-11), `HoldoutClearStore` (09-13). All publish
sidecars into one shared directory, and two of them document in their own
comments that "two saves in flight" race onto the same URL — the wedge condition
verbatim. First wedge: the night of 09-13.

Test hosts wedged most often because Swift Testing runs tests in parallel and
these stores write to the **real** Application Support path (the known settings
pollution class), so several tests publish the same sidecar at once.

---

## THE FIX

`AtomicFilePublish.replaceItem(at:withItemAt:)` in `VideoScanCore` — a temp file
in the destination's own directory, published with plain `rename(2)`. Equally
atomic on APFS, different Sandbox hook, immune. All seven production call sites
converted plus two in the tests; the repo now contains no `RENAME_SWAP`.

`AtomicFilePublishSensorTests` keeps it that way. It is deliberately a **source**
sensor: a test that actually provoked the deadlock would wedge the test host and
cost another reboot, so there is no way to assert on this bug at runtime and
live. It also pins the replacement's behaviour, including 8 tasks × 250
concurrent publishes to one destination.

---

## DISPROVEN — including things this document previously asserted

1. **"Pool saturation on Swift's cooperative executor."** Dead. M5 wedged during
   the A/B's arm B, with `-parallel-testing-enabled NO`. The spindump's
   workqueue note was a symptom of the deadlock, not its cause.
2. **"The M1 A/B showed no wedges in either arm."** The M1 A/B was **void** —
   all four runs died instantly on `childPID > 0`, so no tests ever ran.
   `ab_wedge.sh` counted wedges without checking that the battery executed.
   (The *reason* those launches failed is still unknown — see the symptom
   section. A corpse alone does not do it.)
3. **"The Sandbox hook needs a real App-Sandboxed bundle / container
   bookkeeping."** Wrong. VideoScan sets `ENABLE_APP_SANDBOX = NO`, and the
   reproducer is an ordinary Python process.
4. **"`renamex_np` is the trigger because it is new since `bd05b08a`"** (the POI
   UUID migration). Exonerated — that is `RENAME_EXCL`, a plain rename, and the
   hook in every stack is the *swap* variant.
5. **"Renames in flight while the process exits."** No.
6. **"The machine is globally poisoned."** No — the lock is path-scoped. With two
   corpses present on the M1, ordinary renames and even single-threaded
   `RENAME_SWAP` still completed instantly, and on the M5 a full test host
   launched and ran 60 tests with a corpse present.

Why repros #1 and #2 could not have worked: they never issued a `RENAME_SWAP`,
and they gave every thread its own directory with unique names, so no two
threads ever touched one vnode.

---

## CONTRIBUTING FACTOR (ours, regardless of root cause)

On the night of 2026-09-13 an agent ran the full 7,661-test battery twice,
against the standing policy of focused suites during rapid dev. That is what
turned a rare bug into four wedges in one night and cost the demo. Agents are
restricted to focused suites.

---

## STILL OPEN

- **Report to Apple.** A kext rwlock held across a sleeping VFS operation, by a
  thread of a process that can then never exit, is their bug regardless of what
  provokes it. Attach both spindumps and `wedge_min.py` — 2 threads, 26 ops,
  ~40 lines of Python, no privileges, no sandbox, wedges a process permanently
  and costs a reboot. That is a denial of service any process can inflict on
  itself.
- `scripts/check_wedged_processes.py` belongs in the morning brief so the rate
  is measured, not discovered during a demo.
- M1 and M5 both hold corpses from today's experiments and need a reboot before
  they can run the VideoScan suite again.

## OPEN, UNRELATED, FOUND ALONG THE WAY

- Two VideoScan processes on the M1 stuck in state `T` (SIGSTOP'd) since Sep 7 —
  suspended and never resumed. Our pause machinery sends SIGSTOP
  (`JobPauseCoordinator`). Worth a look.
- The detached `--find-tag` daemon and `videoscan-preview-sweep --watch` survive
  app quit by design, orphaned to launchd, and were observed at ~95–99% CPU each
  after the GUI exited.
