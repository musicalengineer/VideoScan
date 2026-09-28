# Codex reviews — GH #204 rename-backup pruning (data-risk) — night of 2026-09-26→27

Invocation: `codex exec --sandbox read-only` (direct), three scoped passes. Total tokens: 95,800. Findings: 5 + 3 + 0 = 8, all closed red-first. Final verdict: MERGE (main 9d3afbb3).

## Pass 1 — reviewed 3a4fc4f3 — tokens 24,990

Closed by: 1b94b713 (UTC names) → redesign 7ba1a271

### Brief

Adversarial review, SCOPED to ONE commit: 3a4fc4f3 on origin/night/fix-202-204 (GH #204). Use `git show 3a4fc4f3`. Do NOT explore outside the files it touches; read-only; do not build or run.

WHY: these are the backups taken before the app rewrites the Master Archive index (00_Index) and the media ledger during a Catalog rename. Pruning the wrong backup, or two renames sharing one backup folder, loses the only copy of the pre-rename state.

Change: backup folder names are now UTC `yyyy-MM-dd'T'HHmmss.SSS'Z'`; `makeBackupDirectory` creates each folder exclusively (collisions get -2, -3…); both the archive-index and ledger backup writers use it; pruning sorts by parsed date, then -N, then name — never lexically; legacy local-time names still parse (tz parameter defaults to current); unparseable folder names are never counted or pruned; a failed delete is logged.

INVARIANTS TO ATTACK:
1. Retention never deletes the newest N backups, across: DST fall-back, mixed legacy+new names, -N suffixes, a clock that went backwards, names from another machine's time zone.
2. Two backups never share a folder: concurrent renames, same millisecond, a pre-existing folder of the same name, a file (not dir) squatting on the name.
3. Pruning never touches anything that is not one of our backup folders (a user's own folder inside .rename_backups, a symlink, a partially written backup still in progress).
4. A backup that failed to write completely is never counted as a valid backup toward retention.
5. The legacy tz-parameter default cannot misorder legacy names relative to new UTC names by more than the zone offset in a way that prunes a newer backup.

Evidence: M5 Debug 261 tests / 27 suites green incl. LedgerRenameBackupOrderingTests (DST pair, same-ms pair, mixed legacy/new, exclusive folder, source sensor) and LedgerRenameBackupRetentionTests; red shown before the fix and by mutation.

OUTPUT (stdout, Markdown, under 500 words): first line `Credits spent: <n or unavailable> | Finding count: <n>`; `Verdict: merge / merge-after-fixes / hold`; findings with file:line, counterexample, pinning test.

### Verdict

Credits spent: unavailable | Finding count: 5

Verdict: merge-after-fixes

Locations below refer to `VideoScan/VideoScan/ArchiveIndexRename.swift` at `3a4fc4f3`. These are static counterexamples to the requested invariants; some gaps predate this commit.

1. **P1 — In-progress backups are eligible for deletion** — lines 376–385, 452. A creates its folder and pauses before completing its writes. Twenty later backups complete; their pruning deletes A’s folder while A still owns it. Exclusive creation does not protect the folder’s lifetime.
   **Pinning test:** Suspend A after folder creation, complete twenty later backups, and assert A’s folder survives pruning and its writes complete.

2. **P1 — Failed backups evict complete backups** — lines 467–473, 849–850; counting at 376–381. Both writers leave a timestamped directory when a backup write throws. Pruning counts it without checking completeness. With twenty complete backups, one newer failed backup, and one subsequent successful backup, pruning removes two complete backups, leaving only nineteen valid ones.
   **Pinning test:** Inject a backup-write failure after directory creation, then perform a successful rename; assert twenty complete backups remain. Include failure on the second index file.

3. **P1 — A matching name authorizes deletion of unrelated content** — lines 376–385. A user directory named `2000-01-01T000000.000Z`, containing unrelated files, is recursively deleted alongside twenty newer backups. `fileExists(...isDirectory:)` also follows directory symlinks, making a timestamp-named symlink eligible for removal and retention counting. This does not imply deletion of its target.
   **Pinning test:** Seed timestamp-named user directories and directory symlinks; assert neither is counted or removed.

4. **P1 — Clock rollback deletes the latest recovery copy** — lines 382–385, 403. Create twenty backups with September timestamps, then perform the latest rename with `now` in August. Its successful publish immediately prunes its own backup because ordering uses wall-clock timestamps exclusively.
   **Pinning test:** Perform twenty increasing-time ledger renames followed by a backward-time rename; assert the latest twenty backup *contents* survive.

5. **P1 — Legacy timestamps cannot establish the asserted chronology** — lines 415–423. A legacy `2026-11-02T000000.000` written in New York represents 05:00Z. Pruning on a UTC machine interprets it as 00:00Z and deletes it before an older 01:00Z backup. Legacy repeated-hour names likewise lack the information needed to order both DST occurrences reliably.
   **Pinning test:** Mix that legacy backup, the 01:00Z backup, and nineteen later backups; parse with UTC and assert the actually oldest backup is removed. Add a legacy fall-back pair. Unknown provenance requires conservative retention.

`LedgerRenameBackupOrderingTests.swift`: read, no findings in existing assertions; they do not cover these counterexamples.

No builds or tests run; no files changed.

## Pass b — reviewed acfd9f6e (7ba1a271 on main) — tokens 39,609

Closed by: d340afa3, af1fc21f, 9d3afbb3

### Brief

Scoped RE-REVIEW of ONE commit: acfd9f6e on origin/night/fix-202-204 (your 5 P1 findings on 3a4fc4f3, report at /private/tmp/claude-501/-Users-rickb-dev-VideoScan/b3609732-7ed3-42d9-a141-e6ca6f396770/scratchpad/codex-review-204.out). `git show acfd9f6e`. Read-only; do not explore beyond the files it touches; do not build or run.
Design: each backup folder carries `.videoscan-backup.json` {version 1, sequence, createdAt UTC, complete, files+sizes}; the folder is claimed under an exclusive flock on `.rename_backups/` with an INCOMPLETE marker and sequence = max+1; marked complete only after the protected rename is published (both index and ledger writers); pruning counts only real directories (no symlink follow) with a complete v1 marker, ordered by sequence, keeps newest 20; incomplete/markerless/legacy/foreign never counted or deleted; failed backup write removes its own partial folder; a failed ledger write removes its backup; folder-name parser removed.
Verify your #1–#5 are closed and attack the new design: flock on a network/SMB volume or FAT/exFAT (FamilyArchive may be SMB or APFS); marker written atomically?; crash between publish and "complete" (backup stays incomplete forever — acceptable, but does anything else then fail?); sequence parsing of a corrupt/hostile marker; two processes (app + a CLI) racing; a marker that claims complete but lists files that are missing; symlinked `.rename_backups` itself.
Evidence: M5 Debug 265 tests / 28 suites green incl. LedgerRenameBackupProvenanceTests (six pins; #3–#5 red on 3a4fc4f3, #1–#2 red by mutation).
OUTPUT (under 500 words): first line `Credits spent: <n or unavailable> | Finding count: <n>`; `Verdict: merge / merge-after-fixes / hold`; findings with file:line, counterexample, pin.

### Verdict

Credits spent: unavailable | Finding count: 3

Verdict: merge-after-fixes

Original #1–#5 counterexamples are closed by inspection and the supplied pins. Three additional gaps remain. Locations refer to `VideoScan/VideoScan/ArchiveIndexRename.swift` at `acfd9f6e`.

1. **P1 — Refused-rename cleanup can delete another process’s backup** — **363–364**, interacting with **447–454**. A removes its refused backup and observes the parent empty. B then locks that parent, claims a folder, and writes its backup. A recursively removes the parent without acquiring the lock, deleting B’s recovery copy—even while B holds the lock. Removing/recreating the parent also invalidates its role as a stable lock inode. This existing cleanup defeats the new locking design.
   **Pin:** Pause A after its empty-directory check; let B claim and fill a backup; resume A and assert B’s folder survives. Keep the lock directory permanently.

2. **P1 — Missing backup files still authorize eviction of valid backups** — **418–427, 544–548**. `files` and `sizes` are decoded but never checked. Start with twenty valid backups, then add a newer complete-v1 marker listing an absent ledger. Pruning counts twenty-one and deletes the oldest valid recovery copy, leaving nineteen usable backups.
   **Pin:** Seed twenty valid backups plus a newer complete marker with a missing file; repeat with a truncated file. Assert neither defective folder contributes to retention counting and all twenty valid backups survive.

3. **P2 — A corrupt sequence crashes every subsequent backup claim** — **426, 472**. A decodable v1 marker with `sequence: 9223372036854775807` passes validation, including when incomplete. `max + 1` then traps on integer overflow rather than throwing a recoverable error.
   **Pin:** Seed that marker and invoke claiming in a subprocess; assert no trap, existing backups remain untouched, and sequence exhaustion produces a controlled outcome.

Other requested checks: marker writes use `AtomicFilePublish` with `.fullFsync`; its implementation is outside the permitted scope. A crash after publish but before completion leaves an excluded, retained folder; ordinary subsequent claims still advance. A pre-existing symlinked `.rename_backups` is refused by `O_NOFOLLOW`; pruning also checks the parent type. Lock errors fail closed before index/media publication. SMB/FAT/exFAT directory-lock support and cross-client exclusion remain unverified; the reported M5 tests do not establish them.

Changed sections of `ArchiveVolumeProtectionTests.swift`, `CatalogRenameArchiveIndexTests.swift`, `LedgerRenameBackupOrderingTests.swift`, and `LedgerRenameBackupProvenanceTests.swift`: read, no findings in their assertions; the three counterexamples above lack pins.

No builds or tests run; no files changed.

## Pass c — reviewed 917d0005 · 8fa22eac · e2692464 — tokens 31,201

Closed by: merged as d340afa3 · af1fc21f · 9d3afbb3

### Brief

Scoped RE-REVIEW of three commits on origin/night/fix-202-204: 917d0005, 8fa22eac, e2692464 (your three findings on acfd9f6e; report at /private/tmp/claude-501/-Users-rickb-dev-VideoScan/b3609732-7ed3-42d9-a141-e6ca6f396770/scratchpad/codex-review-204b.out). `git show <sha>`. Read-only; nothing beyond the lines they touch; no build/run.
917d0005: `.rename_backups/` is never removed; refused-rename cleanup removes only its own folder under the lock. 8fa22eac: a backup counts only if every listed file is a plain name inside the folder, a regular file (lstat), exact listed size; empty list doesn't count; defective complete folders are logged, never deleted. e2692464: sequence accepted only in 1..<2^40, else foreign; checked addition; exhaustion throws, logged, rename refuses.
Verify your #1–#3 are closed; attack only regressions these three introduce (e.g. a legitimately large ledger whose size changed between write and verify; a verified backup whose file is later modified by the user — should it still count?; lock released before `afterOwnRemoval` hook in production?).
Evidence: M5 Debug 273 tests / 31 suites green; #2 and #3 genuinely red on acfd9f6e (#3 crashed the test process), #1 red by mutation.
OUTPUT (under 300 words): first line `Credits spent: <n or unavailable> | Finding count: <n>`; `Verdict: merge / merge-after-fixes / hold`; findings with file:line, counterexample, pin.

### Verdict

Credits spent: unavailable | Finding count: 0
Verdict: merge

Prior findings #1–#3 are closed by inspection:

- **#1:** Refused cleanup removes only its own folder under `withBackupsLock`; the parent remains permanent. `afterOwnRemoval` executes outside the lock scope, and production callers use its empty default.
- **#2:** Retention requires a nonempty listing of plain filenames, regular files, and matching sizes. Defective complete backups are excluded and preserved. A large ledger has no newly imposed size ceiling. If a backup’s size changes before verification—including a subsequent user edit—it correctly stops counting and remains preserved. Same-size content changes are outside this size-based integrity guarantee.
- **#3:** Out-of-range sequences are excluded before maximum selection. Checked addition and the upper-bound guard turn exhaustion into a logged, thrown refusal before folder creation.

Pins cover concurrent claim survival, missing/truncated files, escaping/empty listings, `Int.max`, rejected bounds, and exhaustion with unchanged ledger contents. The supplied red-test evidence supports the original counterexamples.

Touched sections of `ArchiveIndexRename.swift`, `ArchiveVolumeProtectionTests.swift`, `LedgerRenameBackupIntegrityTests.swift`, and `LedgerRenameBackupOrderingTests.swift`: **read, no findings**.

No builds or tests run; the reported M5 results were supplied evidence. Both specified Manager protocol paths were absent.
