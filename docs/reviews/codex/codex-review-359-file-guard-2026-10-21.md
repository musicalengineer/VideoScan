# Codex review — #359 file guard

- Range: `5c7fb4b3a..bf48fc7dc`
- Credits spent: unavailable (meter not exposed)
- Tokens: 76118
- Finding count: 4
- Verdict: fix — `bf48fc7dc` still has four P1 paths that violate the requested invariants.
- Run: 2026-10-22T01:12:59Z (cycle #117, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (meter not exposed) | Finding count: 4

Verdict: fix — `bf48fc7dc` still has four P1 paths that violate the requested invariants.

1. **P1 — Transient `stat` failure quarantines the live catalog’s committed frames.** [GRDBCatalogRepository.swift:866](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a9c813590f292c280/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:866) treats `.unreadable` as a confirmed move, enabling quarantine at line 892.  
   **Failure scenario:** Commit generation 3 over checkpointed generation 2; make this identity read return `EIO`, then let sidecar reads and renames succeed; close quarantines the unchanged database’s WAL, and reopening loses generation 3. An indeterminate identity must not authorize detaching the live WAL.

2. **P1 — Close uses an identity decision made before waiting for the writer.** [GRDBCatalogRepository.swift:879](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a9c813590f292c280/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:879) awaits the writer queue, but subsequent quarantine still uses the earlier `databaseMoved` value.  
   **Failure scenario:** Leave committed frames in WAL, pause another writer, start close while the original database remains, replace it during the wait, then release the writer; the checkpoint can fail with `SQLITE_IOERR_VNODE`, yet quarantine is skipped and the replacement inherits the WAL. This potentially seconds-long gap is outside the excluded last-stat-to-COMMIT window.

3. **P1 — A timed-out close permits clean termination with foreign WAL attached.** [CatalogQuitRecovery.swift:226](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a9c813590f292c280/VideoScan/VideoScan/App/CatalogQuitRecovery.swift:226) returns after the deadline without ensuring quarantine completed.  
   **Failure scenario:** Commit frames, replace the database, and keep a writer occupied beyond 30 seconds; normal quit terminates before close quarantines the WAL, leaving it available for replay into the replacement. Logging manual recovery instructions does not establish the clean-quit invariant. Those instructions also incorrectly advise removing WAL following a latch-only stop, where it can contain the live database’s committed frames.

4. **P1 — Reopen can clear a stop discovered during close and write into the replacement.** [CatalogCommitter.swift:449](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a9c813590f292c280/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:449) opens unconditionally after awaiting close; the identity check occurs only beforehand.  
   **Failure scenario:** Pass Reopen’s initial check, replace the database while close is pending, and supply a replacement matching the witnesses; even if close correctly detects and quarantines the swap, the new open resets the sticky stop and `becameWritable()` schedules pending edits into that replacement. Recheck the stop after close, before opening.

Read, no independent findings: `CatalogFileGuard.swift`; the remaining scoped repository open/write/adopt/sealed-copy/session sections; `CatalogRepository.swift` additions; committer `saveRefusal`, `admit`, `absorb`, `canReopen`; `VideoScanApp.swift` termination call; and Undo’s `loadSafetyCopy`.

Source review and test inspection only. The reproduction scenarios above were **not executed**; no files were written. The reported green suites do not cover these specific transitions.

## Brief

# Codex brief: GH #359 — after catalog.sqlite is replaced or catalog.cutover removed mid-session, not one more byte lands (2026-10-21; data-risk; Rick approved codex as needed)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~700 words.

**Range:** `5c7fb4b3a..worktree-agent-a9c813590f292c280` (head `bf48fc7dc`, not merged; review it as the candidate).

**Context.** An open SQLite connection writes through its file descriptor, so a renamed or replaced catalog.sqlite kept receiving commits. Apple SQLite's own refusal (SQLITE_IOERR_VNODE 6922) arrives asynchronously and loses the race under load. Rick's rule is fail fast: stop writing and say why.

**What changed.**
- `CatalogFileGuard` records the identity (st_dev + st_ino) of catalog.sqlite, catalog.cutover (if present at open) and this session's -wal/-shm.
- Every write door rechecks before BEGIN IMMEDIATE, before the high-water publish, and before COMMIT: `write`, `writeBlocking`, `WritePlan`, `adopt`/`runAdoption` (after BEGIN and before COMMIT), and `sealedCopyBlocking` (VACUUM INTO). A mismatch makes a sticky stop with words; Reopen is refused and disabled.
- **close():**
  - If the file at the path is still the session's inode: normal TRUNCATE checkpoint; on failure the -wal stays.
  - If it is missing or different: no checkpoint; the session's own -wal/-shm (matching recorded inodes) are renamed into `catalog-wal-quarantine-<stamp>/`, falling back to an in-place `.quarantined-<stamp>` rename. Other processes' sidecars are never touched, and nothing is ever deleted.
  - Notes reach the app's log sink via `lastCloseNotes`.
- App opens use `open(at:requiringLatch: true)`.
- Quit: `CatalogQuitRecovery.closeAfterFileStop` closes the store only when a file-stop exists, bounded at 30 s.
- Undo reads its safety copy with `openSealedSnapshot`/`openReadOnly` (it was opened read-write before, which changed the copy).

**Files (only these):**
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Store/CatalogFileGuard.swift` (all)
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift`: open doors, `finishOpen`, `write`, `writeBlocking`, `WritePlan`, `sealedCopyBlocking`, `adopt`, `runAdoption`, `close`, `fileStopWords`, `lastCloseNotes`, `WriterSession`
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Store/CatalogRepository.swift` (the protocol additions)
- `VideoScan/VideoScan/Catalog/CatalogCommitter.swift`: `saveRefusal`, `admit`, `absorb`, `reopen`, `canReopen`
- `VideoScan/VideoScan/App/CatalogQuitRecovery.swift`: `closeAfterFileStop`; and its call in `VideoScan/VideoScan/App/VideoScanApp.swift` (`applicationWillTerminate`)
- `VideoScan/VideoScan/Volumes/VideoScanModel+VolumeRenameUndo.swift`: `loadSafetyCopy`

**Evidence already run:**
- Three QA rounds. r1 found 1 blocker (the close checkpoint replayed this session's -wal into a replacement), 2 majors (adopt, VACUUM INTO) and 2 minors. r2 found 1 blocker (the quarantine pulled frames out of the live file on a latch-only stop) plus 2 more. r3 was clean on data loss. Every finding was closed red→green.
- Each test hashes every file (db, -wal, -shm, replacement, both witnesses).
- Core: 371 tests in 53 suites. App: 93 tests in 22 suites. Sensor lane 548 green.

**Do only this. Attack two invariants:**
1. After catalog.sqlite is replaced, moved or deleted, or catalog.cutover removed or replaced, during a session, **not one more byte lands in ANY catalog file** (moved-aside db, its -wal, the replacement, the witnesses), across every write door, adopt, sealed copy, close, quit and Reopen.
2. **The live catalog never loses committed frames** when its own file never moved (latch-only stop, moved away and back, a transient stat failure, a quit during a writer job), and **a replacement never inherits this session's -wal** after a clean quit.

At most FIVE findings. P0/P1 = a byte landing after a stop, lost committed frames, or a replacement inheriting a foreign -wal. One-line failure scenario each.

**Known and declared, NOT findings:**
- #362: a CRASH after a swap leaves the old -wal (no open-side WAL vouching; needs a format ruling).
- #361: reads after a swap.
- The microsecond window between the last stat and COMMIT (no OS lock closes it).
- Uncommitted frames SQLite may spill into the -wal before check 2 (never committed).

**Do not explore outside the files listed above and their tests.**

## Findings closed

All four P1 findings were reproduced red first, then fixed and green (Debug, M4, 2026-10-21). Seam added for F1: `CatalogFileIdentity.TestOverride`, a test-only identity-read override keyed by one exact path, so it cannot leak into parallel suites.

| # | Finding | Red (before) | Fix | Green test |
|---|---------|--------------|-----|------------|
| 1 | `close()` treated an unreadable identity as "moved" and quarantined the live WAL | EIO on the db's `stat` → quarantine folder made, `-wal` moved, reopen at gen 2 | `CatalogFileGuard.databaseAtPath()` → `.same` / `.moved` / `.unknown`. Only `.moved` (missing, or another inode) authorizes moving sidecars. `.unknown`: no checkpoint, no quarantine, the `-wal` stays, and the close notes say the identity could not be read and nothing was moved | `CatalogFileGuardCodex117Tests.unreadableIdentityNeverMovesTheWAL` |
| 2 | `close()` decided before waiting for the writer queue | swap while close waited behind a 1.5 s write → no quarantine, the replacement inherited the `-wal` | `decideAtClose` runs ON the writer queue (after every queued write): it reads the identity, records the sticky stop, and checkpoints only on `.same`; quarantine uses that decision | `CatalogFileGuardCodex117Tests.swapDuringTheWriterWaitIsSeen` |
| 3 | a timed-out quit close could leave this session's WAL for the replacement; the words advised removing the WAL after a latch-only stop | replace + hung close → no quarantine; latch-only + hung close → "move …-wal … away" | on timeout the quit calls `quarantineAfterTimedOutClose()`: it renames this session's own `-wal`/`-shm` by inode ONLY when the db is confirmed moved, and is safe under open descriptors. Same file / unreadable / closed: nothing moves, and the words say the catalog's own `-wal` holds committed changes that will be applied at the next open | `CatalogAuthorityCornerTests.quitTimeoutAfterReplaceStillQuarantines`, `quitCloseIsBoundedAndKeepsTheLiveWAL` |
| 4 | Reopen checked the stop only before close | swap during close → Reopen opened the replacement (`openCalls` 1), no refusal | `CatalogCommitter.reopen` re-checks `fileStopWords` AFTER close and BEFORE open; a stop refuses with the same words and opens nothing (close records the stop on the writer queue) | `CatalogAuthorityCornerTests.reopenRechecksAfterClose` (with `SwapOnCloseRepository`) |

Regression evidence on the fix commit:
- Core FileGuard / OpenCorner / close-checkpoint / store sensor: 39 tests in 6 suites, green.
- Core catalog/store-wide: 373 tests in 54 suites. One load-sensitive miss, the disk-full "edits land once space returns" retry. It passes alone: `CatalogWriteCornerDiskTests` 4 of 4.
- App corner / Quit / Undo / committer / adopt / flip suites: 56 tests in 9 suites, green.
- Sensor lane: see the commit report.
