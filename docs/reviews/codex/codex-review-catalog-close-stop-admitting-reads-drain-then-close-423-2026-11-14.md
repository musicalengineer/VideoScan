# Codex review — Catalog close: stop admitting reads, drain, then close (#423)

- Range: `origin/main..HEAD`
- Credits spent: unavailable
- Tokens: 132523
- Finding count: 0
- Verdict: merge — no defects found in the scoped admission, drain, continuation, or writer-ordering paths.
- Run: 2026-11-14T19:14:25Z (cycle #291, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 0  
Verdict: merge — no defects found in the scoped admission, drain, continuation, or writer-ordering paths.

- [GRDBCatalogRepository.swift](/Users/rickb/dev/VideoScan-wt/close-drain/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift): read, no findings.
- [CatalogCloseDrainTests.swift](/Users/rickb/dev/VideoScan-wt/close-drain/VideoScan/VideoScanCore/Tests/VideoScanCoreTests/Store/CatalogCloseDrainTests.swift): read, no findings.

All reader entry points are covered, including the extension audit. Admissions balance on success, throw, and cancellation; `verify` retains its admission across both reads. GRDB finishes releasing the reader before the repository decrements its count.

The drain continuation has no lost-wakeup window. Concurrent closes wait for the first, without repeating its checkpoint or pool close. Open remains refused during closing, and completion clears the state for reopening.

The drain preserves writer ordering: identity inspection and checkpoint still execute together on the writer queue, after writes queued ahead of them. No close/read dependency cycle was found in the inspected callers.

The timeout fallback remains valid while reads drain: it operates off the actor, checks database identity, and quarantines only matching sidecar inodes. It does not require completed close.

Scope note: `Persistence` is absent; quit recovery lives under `App/CatalogQuitRecovery.swift`. GRDB cancellation internals and the quarantine helper were traced for invariants 2 and 8.

Reviewed commit `216029590`. Tests were not run in the read-only sandbox; the supplied TSan results were not independently reproduced.

## Brief

# Codex review brief — catalog close: stop admitting reads, drain, then close (GH #423)

**Workflow in one sentence:** "closing the catalog never races a read: a read that arrives once close has begun is refused, and close waits for the reads already inside."

**Range:** `origin/main..HEAD` (one commit) · **Worktree:** `/Users/rickb/dev/VideoScan-wt/close-drain`

**In scope (read these and their direct callers; nothing else):**
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift` — the new actor state (`closing`, `readsInFlight`, `drained`, `closeWaiters`), `admitRead()`, `readReturned()`, `closeDrainState`, and their uses in `read`, `verify`, `adopt`, `pragmas`, `close`.
- `VideoScan/VideoScanCore/Tests/VideoScanCoreTests/Store/CatalogCloseDrainTests.swift` (new).

**Background.** The weekly Thread Sanitizer run reported GRDB 7.11.1 `DatabasePool.close()` writing `readerPool = nil` (DatabasePool.swift:283) while `DatabasePool.read(_:) async` read it (:357). The repository is a Swift actor; the actor is released at each `await pool.read`, so `close()` could run while another read was starting. With the fix switched off by mutation, the new tests reproduce it: readers get `SQLite error 21 … BEGIN DEFERRED TRANSACTION`, and `swift test --sanitize thread` prints the same DatabasePool.swift:283 report. With the fix: 58 tests in 7 suites pass under Thread Sanitizer with 0 reports.

**Invariants to attack:**
1. No `pool.read` on the actor's own open pool can START after `closing` is set, and `pool.close()` / `decideAtClose` cannot run while `readsInFlight > 0`. Find any actor method (in this file or the `GRDBCatalogRepository+*.swift` extensions in the same folder) that reaches the pool's READER side without `admitRead()`.
2. The count never leaks or goes negative: every `admitRead()` that returned true is matched by exactly one `readReturned()` on every path (throw, early return, cancellation of the calling Task). A leak means close never finishes.
3. Continuations: `drained` and each `closeWaiters` entry is resumed exactly once; never zero times (a hang) and never twice (a trap). Consider: two closes; close when nothing is open; close → open → close; a read returning at the instant close suspends.
4. A second `close()` during the first must not run the checkpoint or `pool.close()` a second time, and must not return before the first has finished.
5. `open()` during a close in flight is still refused ("already open") and the flags are clean for the next open after close completes.
6. Nothing about WRITES changed: `write`, `writeBlocking`, `sealedCopyBlocking`, `adopt`'s write and `decideAtClose` behave as before (the #359 / codex #117 ordering — the identity read and checkpoint run on the writer queue after every queued write — must be intact). Say if the drain, which now runs BEFORE `decideAtClose`, weakens any of those guarantees (for example a write admitted during the drain).
7. A deadlock: is there any caller that awaits `close()` from inside a read body, or holds a read open until something that itself waits on close? (`rg "\.close\(\)"` in `VideoScan/VideoScan/Catalog` and `VideoScan/VideoScan/Persistence` is in bounds for this one question.)
8. The app's quit path has a timed-out-close fallback (`quarantineAfterTimedOutClose`). Does waiting for reads change what that fallback may assume?

**Known and accepted (do not report):**
- New writes are not refused while close drains (unchanged behaviour; `writeBlocking` reads the gate off the actor). Out of scope unless it breaks invariant 6.
- GRDB's own race still exists inside GRDB; this change stops the repository from driving it. The suppression in `scripts/sanitizer/tsan.supp` and the CONTROL test in `GRDBCloseTSanReproTests` are retired in a follow-up commit.
- A read that never returns makes close wait forever; reads are synchronous SQL closures and the quit path has its own timeout.
- You cannot run tests in the read-only sandbox.

**Output contract:**
```
Credits spent: <amount> | Finding count: <N>
Verdict: merge | fix | block — <one sentence>
```
Then findings ranked by risk (a hang at close or a lost/duplicated checkpoint is the top class), each with `file:line`, a reproduction, and a RED test where possible. For each in-scope file with nothing to report write "read, no findings." Do not explore outside these files except where an invariant above says so.
