Brief: C02 | Source: main@959c7d7 | Wall clock: ~30 | Files read: 22
Finding count: 9 (REAL 8 / NEEDS-MAC 1 / NOISE 0)
Verdict: No P1 found. The copy → verify → publish → index chain converges after a crash at every step. The weak spots are around it: two Promote jobs running at once, a torn index tail after a short write, a crash in the middle of Update…, and the ledger's timing.

## How this pass ran

- **The promote write path, journal, lock, ledger, re-adoption and file lock** were read in this session.
- **Invariant 4 (Update… / Refile / index rename / AtomicFilePublish)** went to a fresh-context `qa` subagent. Every finding it reported was re-checked against the source here before being kept (F3, F7, F8, F9).
- **Scope note:** this ran on the session's assigned branch `claude/compassionate-babbage-kn9mbj`, not `cloud/C02`. The harness forbids pushing to any other branch without explicit permission.

**Files read (scope):**
- `PromoteToArchiveJob`, `+Steps`, `+Guards`
- `ArchivePromoteEngine` (index-file primitives, publish body, partial removal)
- `ArchivePromoteJournal`, `ArchivePromoteDecisions`, `ArchiveIndexLock`
- `MasterArchive` (the manifest section), `MasterArchiveReadoption`, `ArchiveFileLock`
- `MediaLedger`, `VideoScanModel+MediaLedger` (append entry points)
- Subagent: `ArchiveRefile`, `VideoScanModel+ArchiveUpdate`, `ArchiveIndexRename`, `ArchiveIndexText`, `VideoScanCore/AtomicFilePublish`

**Callees followed to settle findings:**
- `MediaFileOperationsCenter.startPromote` (MediaOps/MediaFileOperations+Promote.swift)
- `MediaFileOperationsCenter.gatePlan` and `MediaVolumeGatePolicy.compareSlots` (MediaOps/MediaFileOperations.swift:554, :1382)
- `VideoScanModel.registerPromotedCopy` (Archive/VideoScanModel+MasterArchive.swift:1142)
- `ArchiveAngelPromoter`'s call to `startPromote` (ArchiveAngel/Promote/ArchiveAngelPromoter.swift:301)
- `PromoteToArchiveSheet.confirm` (Archive/PromoteToArchiveSheet.swift:487)

## Invariant 1 — crash step table (one file, fresh copy)

| # | Step just finished | Disk if the process dies here | Next Promote run (reconcile) | Result |
|---|---|---|---|---|
| 0 | Guards, duplicate claim, source digest proven | nothing written | — | clean |
| 1 | journal `intent` (fsync, under index lock) | journal line only | dest absent → remove `.partial` (none) → `abandoned` | clean |
| 2 | `.partial` created / copying / verifying | `intent` + `.partial` (+ any new empty folders) | dest absent → `removeContainedPartial` → `abandoned` | clean (empty folders stay, cosmetic) |
| 3 | F_FULLFSYNC partial → `renameatx_np(RENAME_EXCL)` → fsync dir | `intent` + final file, **no digest in journal** | hash dest; expected = source's hash (journal has none, manifest has no row) → equal ⇒ finish | clean while the source is unchanged; otherwise the verified copy stays **unindexed and unlinked** (F5) |
| 3b | dir fsync fails after rename | engine unlinks its own just-published name | as step 2 | clean (source untouched) |
| 4 | journal `renamed` (sha) | file + `renamed` | verify against journaled sha ⇒ finish | clean |
| 5 | UF_IMMUTABLE set | locked file + `renamed` | verify (read only) ⇒ lock is `alreadySo` ⇒ finish | clean |
| 6 | manifest row + F_FULLFSYNC | row + `renamed` | verify ⇒ `appendsRow` false (row exists, record_id reused) | clean |
| 7 | journal `published` | row + `published`; catalog link in memory, maybe saved by the debounce | linked ⇒ queue `done`; not linked ⇒ re-register from row/journal | clean |
| 8 | batch-end `saveCatalogNow()` true → `done` lines | all durable | `done` is trusted | clean |
| 9 | ledger `archived` (+ `dateSet`) appended on the ledger worker | — | **reconcile never re-emits a missing ledger line** | ledger can miss the line (F4) |

**Conclusion:** no step ends with a record marked archived whose archive copy is missing or unverified.
- Every path into `registerPromotedCopy` / `registerOrphanPromotedCopy` goes through `finishPublished`, and all its callers verify the digest first:
  - fresh copy: the engine's read-back;
  - adoption: `identicalDigest`, and `adoptFromManifest`'s rehash;
  - reconcile: rehash against the journal, manifest or source digest.
- A failed save leaves the journal at `published`, and reconcile re-links.

## Guards checked that held

- **Never clobber (promote):**
  - The partial is created with `O_CREAT|O_EXCL|O_NOFOLLOW`.
  - Publish is `RENAME_EXCL`.
  - `chooseDestinationOffMain` probes each candidate on disk through the dirfd chain, so on case-insensitive APFS "A.mov" finds "a.mov" and the name counts as taken. An in-flight `.partial` also counts as taken.
  - A same-name collision is adopted only on byte identity, checked against a digest proven in this run.
- **Index lock:**
  - Manifest, journal, decisions and attestation appends, and the whole index-rename apply, run inside `ArchiveIndexLock.withExclusive`.
  - The lock is `flock` on the 00_Index directory. The kernel drops it when the holder dies, so a stale holder cannot exist and there is no stealing code to attack.
  - A second process or a second open in the same process is excluded.
  - On the main thread the lock is tried once and never slept on.
  - Hand edits cannot be locked out. The index-rename path catches them with an inode + size + mtime recheck before each publish.
  - SMB/exFAT exclusion is unverified, and the code says so.
- **Archived is read-only (subagent, re-checked):**
  - Update is a single `renameatx_np(RENAME_EXCL)` relative to directory descriptors. `EXDEV` refuses, so it never copies and deletes.
  - Content bytes are never written.
  - The source is identity- and digest-checked before the move; identity and digest are checked again after it.
  - Containment refuses moves out of the archive or into 00_Index.
- **AtomicFilePublish:** index rewrites publish with `AtomicFilePublish.write(.fullFsync)` (rename(2)). There is no `replaceItemAt` on these paths.
- **Ledger (invariant 5):** an `archived` line is only collected after the file is fsync'd and the manifest row is F_FULLFSYNC'd. It is appended after the batch's catalog save.
- **Re-adoption:** `MasterArchiveReadoption` is read-only (lstat plus an O_NOFOLLOW|O_NONBLOCK count) and routes through the create-if-missing Initialize sheet.

## Findings

### C02-F1 — P2 · REAL · A second Promote job's start-up reconcile treats a running job's in-flight entries as crash leftovers
- **Symbol:** `PromoteToArchiveJob.reconcileJournal` — Archive/PromoteToArchiveJob+Steps.swift:132-201 (partial removal at :165, re-registration at :186).
- **Enabling condition:** `MediaFileOperationsCenter.startPromote` (MediaOps/MediaFileOperations+Promote.swift:33-42) refuses a second job only when the record sets overlap.
- **Why the volume gate does not serialise jobs:** `gatePlan` gives an SSD archive no gate and a RAID/unknown archive 2 slots (MediaFileOperations.swift:554-571). Two Promote jobs over disjoint files (for example an Archive Angel batch plus a sheet promote from another drive) therefore run at the same time.
- **Scenario A (likely):**
  1. Job A is copying a large file S. Its journal says `intent` and `S.partial` is being written.
  2. Job B starts and runs `reconcileJournal`. It sees S's latest entry is `intent`, S has no catalog link, and the destination is absent.
  3. Job B calls `removeContainedPartial`, which unlinks A's live partial, and appends `abandoned`.
  4. A keeps writing to the unlinked descriptor, verifies, and then `renameatx_np` fails with ENOENT. After a full multi-GB copy, S is reported FAILED.
- **Scenario B (narrower window):**
  1. A has written `renamed` and is inside `finishPublished` (lock, then a probe of several seconds).
  2. B's reconcile hashes the destination and it matches.
  3. A appends its manifest row and registers copy record X.
  4. B then calls `finishPublished` with its own pre-run manifest snapshot. It does not re-check the catalog link after the hash await.
  5. B appends a second manifest row for the same file with a fresh record_id Y. `registerPromotedCopy` replaces X with Y by path.
  6. Result: the manifest's X row now has no catalog record, and the ledger gets duplicate `archived` lines.
- **Impact:** no family bytes are lost; the damage is a failed file and a doubled index row.
- **Pinning test:**
  1. Write a journal `intent` for record S and create `<dest>.partial`, as a live job would.
  2. Register an active `PromoteToArchiveJob` with S in its plan in the Center.
  3. Run a second job whose plan does not include S.
  4. Assert `<dest>.partial` still exists and no `abandoned` line was written for S. This fails today.
- **Fix direction:** reconcile should skip sources owned by any active Promote job, or refuse to start a second Promote while one is active. `hasActivePromote` already exists.

### C02-F2 — P2 · REAL · A short write leaves a torn index tail, and the next append is glued onto it
- **Symbol:** `ArchivePromoteEngine.appendDurable` (Archive/ArchivePromoteEngine.swift:786). Used by:
  - `ArchiveManifestCSV.append` (Archive/MasterArchive.swift:777)
  - `ArchivePromoteJournal.append` / `appendRetractable` (Archive/ArchivePromoteJournal.swift:52, :78)
  - `ArchivePromoteDecisions.record`
- **Scenario:**
  1. `write()` returns short, for example ENOSPC on the archive volume while large copies are filling it. The bytes already written stay in the file, with no newline.
  2. `appendDurable` throws, so that file fails correctly.
  3. The next successful append (the next file's row) lands on the same physical line.
  4. `fieldRowsBySource` / `ArchiveDigestIndex` then misread or skip the glued line. The new row, which the journal records as `published`, is invisible to the manifest-leg idempotency check and to GH #190 duplicate detection, and a rebuild from the manifest loses that file's provenance.
- **Guards looked for:**
  - Nothing checks that the file ends in `\n` before appending.
  - Nothing truncates back to the pre-append size on a short write.
  - A grep for any trailing-newline repair in the archive code found none.
- **Impact:** the archive file itself is fine; the index loses the row.
- **Pinning test:**
  1. Create a manifest whose last data row has no trailing newline.
  2. Call `ArchiveManifestCSV.append(row)`.
  3. Assert `ArchiveManifestCSV.rowsBySource(rootPath:)[row.sourceRecordID] != nil`. This fails today.
- **Fix direction:**
  - Under the lock, `fstat` and `pread` the last byte and prepend `\n` when it is missing.
  - Or `ftruncate` back to the pre-write size on a short write.

### C02-F3 — P2 · REAL · A crash in the middle of Update… leaves file, index and lock flag out of step, with nothing in the archive recording the move (subagent; re-checked)
- **Symbol:** `ArchiveRefileEngine.moveAndVerify` (Archive/ArchiveRefile.swift:764-815) with `ArchiveIndexRename.applyLocked` (Archive/ArchiveIndexRename.swift:322-389).
- **Scenario:**
  1. Update clears UF_IMMUTABLE, renames from → to and fsyncs both folders.
  2. It then hashes the whole file at `to` (:799-806), which takes minutes for a multi-GB tape.
  3. A force-quit, crash, power loss or unplug in that window leaves:
     - the file at `to`, unlocked;
     - the manifest and journals still naming `from`;
     - an incomplete `.rename_backups/<n>/` folder.
- **No recovery record:** `BackupMarker` (ArchiveIndexRename.swift:485-499) records only sequence, createdAt, complete and files. It does not record from/to, and nothing reconciles an incomplete marker at start-up. The only record of the intended move is a log line.
- **Same state, second window:** between the manifest publish and the journal publishes.
- **Impact:** no bytes are lost, and Verify Copies will flag the missing row and the unlocked file. But the repair is by hand, and "archived is read-only" (locked) stays broken until then.
- **Pinning test:** run an Update; read the backup marker; assert it contains both `from` and `to`. This fails today because the marker has no intent fields. (A sketch is in the subagent output, ready to drop into `ArchiveUpdateTests` with `UpdateFixture`.)
- **Fix direction:** write from/to into the marker before the move, and have Verify (or start-up) offer the reconcile.

### C02-F4 — P3 · REAL · The `archived` ledger line is not tied to the journal: lost after a late crash or a failed write, duplicated after a failed save
- **Symbol:** `PromoteToArchiveJob.finishRun` / `flushLedger` (Archive/PromoteToArchiveJob.swift:336-401), and reconcile's already-linked branch (+Steps.swift:150-153).
- **Lost:**
  1. `finalizeBatch` writes `done` before the ledger worker writes the batch's `archived` lines.
  2. A crash in between, or a ledger write failure (`writeOffMain` only logs it), loses those lines for good.
  3. Reconcile skips `done` entries, and its already-linked branch emits no ledger event.
- **Duplicated:**
  1. When `saveCatalogNow()` returns false, the `archived` and `dateSet` lines are appended anyway. The `dateSet` fact (the date on the archived record) is not yet durable.
  2. The next run's reconcile re-registers the copy and appends a second `archived` line.
- **Impact:** narration and audit only. Protection and prune read the catalog, not the ledger.
- **Pinning test:**
  1. Give `MediaLedger` a writer seam that fails.
  2. Promote one file, then run a second Promote with an empty plan.
  3. Assert the ledger now holds one `archived` line for that record. Today it holds 0.

### C02-F5 — P3 · REAL · The journal `intent` omits the digest that was already proven, so step-3 recovery depends on the source still being there
- **Symbol:** `PromoteToArchiveJob.copyOrAdopt` — Archive/PromoteToArchiveJob+Steps.swift:352-356 (`sha256: choice.identicalExistingSHA`, which is nil on the copy path, although `digest` was proven at :318-328).
- **Scenario:**
  1. A crash happens after `RENAME_EXCL`, before `renamed` is written.
  2. Before the next Promote run, the source is changed or its drive is gone.
  3. Reconcile has no expected digest (journal nil, no manifest row, source unreadable). It leaves the verified copy in place, unindexed and unlinked, and logs "check it by hand".
- **Impact:** the copy is safe but orphaned, and GH #190 duplicate detection cannot see it.
- **Pinning test:**
  1. Write a journal `intent` with no sha for record S.
  2. Place the file at its destination and delete the source path.
  3. Run reconcile and assert the manifest gains a row for S. That needs the intent to carry the digest; it fails today.

### C02-F6 — P3 · REAL · The ledger mirror writes into 00_Index without `ArchiveIndexLock`
- **Symbol:** `MediaLedger.mirrorFile` — Archive/MediaLedger.swift:246-261.
- **Breaks the brief's literal rule:** "every writer of 00_Index holds ArchiveIndexLock".
- **What it does:** writes a fixed `.media-ledger.jsonl.tmp` (O_TRUNC) and then renames it over `media-ledger.jsonl`.
- **When it matters:**
  - Within one process the ledger's `tail` chain serialises it.
  - Two app instances on the same archive could interleave writes into the same temp file and publish a torn mirror.
- **Impact:** the mirror is a derived copy that the next clean promote rewrites, and nothing else writes that file.
- **Pinning test:** a source sensor asserting that `mirrorFile`'s body runs inside `ArchiveIndexLock.withExclusive`. It fails today.

### C02-F7 — P3 · REAL · Update's manifest collision check is case-sensitive while the disk is not (subagent; re-checked)
- **Symbol:** `ArchiveRefileEngine.preflight` — Archive/ArchiveRefile.swift:463 (`rows.contains { $0.relPath == to }`).
- **Scenario:**
  1. The manifest has a row for `…/x_clip.mov` whose file is gone.
  2. An Update targets `…/x_Clip.mov`. It passes the manifest check (exact match) and the disk check (the file is absent).
  3. Two manifest rows now resolve to one file on case-insensitive APFS, and Verify reports a false fixity mismatch for the other row.
- **Pinning test:** append such a row, then run `updateArchivedFile` to the case variant. Expect `.refused`; today the result is `.updated`.

### C02-F8 — P3 · NEEDS-MAC · A capitalisation-only rename in Update… is always refused, with a misleading message
- **Symbol:** `ArchiveRefileEngine.preflight` → `targetRefusal` — Archive/ArchiveRefile.swift:464.
- **Scenario:**
  1. The slug keeps case, so `to` differs from `from` only in case.
  2. On case-insensitive APFS the target probe opens the source itself.
  3. The update is refused with "a file already exists".
- **Impact:** it fails safe (no clobber) but blocks a common typo fix. A fix must not simply skip the probe. `RENAME_EXCL` on the same vnode, and the move-back identity logic, need checking on a Mac.
- **Pinning test:** Update `…_thanksgiving.mov` to name "Thanksgiving". Expect `.updated`; today it is refused.

### C02-F9 — P3 · REAL · An index-only Update (from == to) backs up and republishes every journal that mentions the path
- **Symbol:** `ArchiveRefileEngine.indexPlan` — Archive/ArchiveRefile.swift:540-547.
- **What happens:**
  1. `Replacements.values` becomes `[from: from, abs: abs]`.
  2. `rewriteJSONL` (ArchiveIndexRename.swift:915-956) records an edit for every matching token even when the new value equals the old, so `changedLines > 0`.
  3. Every journal that mentions the path is backed up, re-encoded and republished for what is a manifest-only date or confidence change.
- **Impact:** this widens the index-rewrite window, and an unrelated journal failure can roll back a manifest-only change.
- **Pinning test:** a known/estimated-only Update; assert the promote journal's bytes are unchanged and it is absent from `.rename_backups`. Fails today.

## Not covered
- `registerOrphanPromotedCopy` and `ArchiveDigestIndex` internals (trusted as read through their callers).
- The Initialize write path in `MasterArchive.swift` beyond the manifest section (create-if-missing was taken from its comments, not read).
- `ArchiveLockJob` and `VideoScanModel+BackupAttestations` as 00_Index writers (both are listed as lock holders by grep, but their bodies were not read).
- Anything on SMB/exFAT (flock semantics).
- Nothing was built or run. The pinning tests are sketches, not executed.
