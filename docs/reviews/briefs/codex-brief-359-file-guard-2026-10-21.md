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
