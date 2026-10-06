Brief: N1008-T-Archive | Source: main@c86b926 | Wall clock: ~40 | Files read: 31
Finding count: 10 (REAL 9 / NEEDS-MAC 0 / NOISE 1)
Verdict: The Archive write path is well pinned (the GH #190 duplicate refusal, Update's rollback, the index lock, the unlock refusal and Verify all go red if their guard is deleted), but two digest checks have no test: the engine's copy-versus-source compare and reconcile's "confirm before indexing". Deleting either would ship silently.

## How this pass ran

- **Read-only.** Nothing was built or run (Linux, no Xcode). The report was not committed or pushed: the caller's brief overrides README rule 3.
- **Source:** the session branch's Archive and test folders are byte-identical to `origin/main@c86b926` (`git diff --stat HEAD origin/main` over both folders is empty).
- **History:** the clone was shallow from 10-04. It was deepened with `git fetch --shallow-since=2026-09-01`. `git log -- VideoScan/VideoScan/Archive` still stops at the 09-29 feature-folder rename (04f631ab), so Update…, the lock and Verify, which predate it, were judged from their test files.
- **Method:** for each guard, I read the guard line, then grepped the whole test folder for:
  - the type and function name;
  - the refusal message string;
  - the failure enum case.

  I then read the assertions of every candidate test. A guard counts as pinned only when some assertion would flip if the guard line were deleted.

**Source files read (scope):**
- `ArchivePromoteEngine` (publish body, index-file open, append)
- `PromoteToArchiveJob+Steps` (reconcile, `promoteOne`)
- `PromoteToArchiveJob+Guards`
- `MasterArchive` (manifest append and validate)
- `ArchiveIndexLock`
- `ArchiveFileLock`
- `ArchiveRefile` (preflight, `moveAndVerify`, `moveBack`)
- `ReadOnlyVolumeProtection`
- `VerifyArchiveCopiesJob` (per-item verdict)
- `BindFixityToVolumeJob` (header and guard list)

**Test files read (assertions):**
- `ArchivePromoteEnginePipelineTests`, `MasterArchivePromoteTests`, `MasterArchiveHardeningTests`
- `PromoteRefusalRollbackTests`, `PromoteArchiveIntegrityRuleTests`, `PromoteDatesAndLockTests`
- `ArchiveUpdateTests`, `ArchiveUpdateSafetyTests`, `ArchiveUpdateSensorTests`
- `ArchiveLockUpdateAndJobTests`, `ArchiveVolumeProtectionTests` (source sensors)
- `ReadOnlyVolumeTests`, `ReadOnlyVolumeCodex258Tests`, `DeleteDuplicatesCodex258Round4Tests` (r5e/r5f only)
- `BackupAttestationJournalTests` (log sink only), `ArchiveTimelineMenuLayoutTests`, `VerifyDisagreementLogBoundTests`
- Test names only: `VerifyArchiveCopiesTests`, `PromoteArchiveIntegrityTests`, `PromoteAdoptionProofTests`, `FixityStampVolumeIdentityTests`, `ArchiveProgressTests`, `VerifyDateSensorReviewTests`

**Callees followed:**
- `TranscodeSheet.defaultToArchiveYearFolder` and `TranscodeJob.existingFilePolicy` (MediaOps), for the 10-05 "Make a Copy" entry.
- `ArchiveAttestationJournal.append`, to confirm it takes the index lock (it does).

## Guard → test

"Red if deleted" means at least one assertion in the named test fails when the guard line is removed.

| # | Guard (symbol, file:line) | Pinning test (file › test) | Pinned? |
|---|---|---|---|
| 1 | Engine: source identity re-sampled after copy (`publishIntoDirectory`, ArchivePromoteEngine.swift:516) | MasterArchivePromoteTests › `engineToctou` (appends a byte from the progress callback; expects a throw, no dest, no partial) | yes |
| 2 | Engine: copied bytes == the checked digest (GH #190, :521) | PromoteArchiveIntegrityRuleTests › `engineExpectedDigest`; PromoteRefusalRollbackTests › `engineRemovesCreatedFolders` | yes |
| 3 | **Engine: verify pass digest == copy digest (:529)** | none | **no → F1** |
| 4 | Engine: partial opened `O_CREAT\|O_EXCL\|O_NOFOLLOW` (:497) | none behavioural (`partialExists` is never asserted) | **no → F1** |
| 5 | Engine: F_FULLFSYNC before publish; dir fsync failure withdraws the name (:537, :549) | MasterArchiveHardeningTests › `barrierFailuresAreNotClaimed` (4a) | yes |
| 6 | Engine: publish is `renameatx_np(RENAME_EXCL)` (:541) | MasterArchivePromoteTests › `engineToctou` (second publish to the same name must throw); ArchiveVolumeProtectionTests › `noUnreviewedNoClobberRename` / `noUnreviewedClobberingRename` (count sensors) | yes |
| 7 | Reconcile: journal relpath containment first (PromoteToArchiveJob+Steps.swift:141) | MasterArchiveHardeningTests › R4-A "journal entry / manifest row with a relpath outside the root…" | yes |
| 8 | **Reconcile: on-disk digest must equal journal / manifest / source digest before indexing (:182)** | none: every reconcile test plants byte-identical files | **no → F2** |
| 9 | **Reconcile: intent + no file → remove the stale partial, write `abandoned` (:163-167)** | none: no test plants a `.partial` with an intent, and nothing asserts `abandoned` | **no → F5** |
| 10 | Manifest append: must exist, regular, not a symlink (MasterArchive.swift:782) | MasterArchiveHardeningTests › `manifestSymlinkRefused` (3b), `missingManifestRefused` (3c) | yes |
| 11 | **Manifest append: header check (MasterArchive.swift:783 `expectedHeaders:`)** | only via `validate` (3c, ArchiveReadinessTests); `append` itself is never called on a header-less file | **append leg no → F4** |
| 12 | ArchiveIndexLock excludes a second holder (ArchiveIndexLock.swift:68) | ArchiveUpdateSafetyTests › `lockExcludes`; CatalogRenameArchiveIndexTests › M1 (catches `Busy`) | yes |
| 13 | Every 00_Index appender holds the lock | ArchiveUpdateSensorTests › `everyIndexWriterHoldsTheLock` (lock-site and `appendDurable` counts) | yes (counts, not nesting; see F10) |
| 14 | ArchiveFileLock: unlock refused unless `.updateUnlock` (ArchiveFileLock.swift:103) | PromoteDatesAndLockTests › `onlyAllowedReasonsUnlock` (every reason); ArchiveLockUpdateAndJobTests › `unlockReasons`, `unlockCallSites` | yes (bypass not sensed → F7) |
| 15 | Refile: grant must cover the move (ArchiveRefile.swift:422) | ArchiveUpdateSensorTests › `oneEngineCallSite` (source string); ArchiveUpdateTests › `grantRefusals` | yes |
| 16 | Refile: archive volume read-only → refuse (:430) | ArchiveUpdateTests › `refusalsBeforeMutation` | yes |
| 17 | Refile: pre-move fixity of the source (sourceCheck) | ArchiveUpdateTests › `refusalsBeforeMutation` ("does not match its manifest fingerprint") | yes |
| 18 | Refile: file on disk at the target → refuse (`targetRefusal`, :480) | ArchiveUpdateTests › `targetExists` | yes |
| 19 | **Refile: manifest already lists the target (:463); one path with several digests (:455)** | none | **no → F3** |
| 20 | Refile: identity re-checked through the dirfd just before the rename (:752) | ArchiveUpdateSafetyTests › `sourceSwappedBeforeMoveIsRefused` | yes |
| 21 | Refile: post-move fixity → put back (:812) | ArchiveUpdateSafetyTests › `rollbackFlushFailure(.verify)`, `blockerAtOldPath` | yes |
| 22 | Refile: never put a stranger back (`moveBack`, :839) | ArchiveUpdateSafetyTests › `strangerIsNeverPutBack` | yes |
| 23 | Refile: index failure rolls back, byte-identical | ArchiveUpdateTests › `rollbackOnIndexFailure`; ArchiveLockUpdateAndJobTests › "rolled back: the index publish fails…" | yes |
| 24 | Promote refuses on a read-only catalog | MasterArchiveHardeningTests › `readOnlyRefused` (2) | yes |
| 25 | GH #190 digest duplicate refusal (`claimSourceDigest`, +Guards.swift:87) | PromoteArchiveIntegrityTests › "promote A, then a byte-identical B…", "after a RELAUNCH…", both RACE tests, the container matrix and the SENSOR | yes |
| 26 | Adoption proves current source bytes | PromoteAdoptionProofTests (3 tests) | yes |
| 27 | Archive volume removal-time re-check | ArchiveVolumeProtectionTests › `deleteDuplicatesRefusesAnArchiveVolumeFileAtDeleteTime`, `removalTimeRecheckCatchesAVolumeMountedAfterTheSnapshot`, `unresolvableDesignationRefusesWhatItCannotProve`; Round4 › r5f | yes |
| 28 | Read-only drive: unreadable identity at removal is not cleared (ReadOnlyVolumeProtection.swift:275) | ReadOnlyVolumeTests › `atRemovalTheFilesOwnVolumeIdentityIsAsked`; Round4 › r5e | yes |
| 29 | **Read-only marked FOLDER: place on the drive unknown → refuse (:304)** | none | **no → F6** |
| 30 | Verify: mismatch / missing / root yanked / read-only viewer / `..` path | VerifyArchiveCopiesTests (MISMATCH, MISSING ×2, UNREACHABLE ×2, read-only viewer, raw link/../ path) | yes |

## Findings

### N1008-T-Archive-F1 — P2 · REAL · The engine's verify compare has no test that goes red if it is deleted
- **Symbol:** `ArchivePromoteEngine.publishIntoDirectory`, Archive/ArchivePromoteEngine.swift:529 (`guard destSHA == sourceSHA`). Also :497, the `O_EXCL` on the partial.
- **Why nothing catches it:**
  - Every engine test copies honestly. `.verifyMismatch` appears nowhere in the test folder.
  - The `barriers` seam only fails fsyncs; it cannot corrupt bytes.
  - The partial's `O_EXCL` is never exercised: no test pre-creates a `.partial` and asserts `partialExists`.
- **Regression that would ship undetected:** a refactor of the pipelined copy (it has been reworked for speed) drops the guard, or compares the wrong variable. A partial whose bytes were damaged on the way to the archive drive is then:
  1. published,
  2. journaled `renamed` with the source's digest,
  3. written into the manifest with that digest,
  4. linked as the source's verified archive copy.

  The damage surfaces only on the next Verify Archive Copies run, after the source may already have been pruned as "archived".
- **Smallest test** (ArchivePromoteEnginePipelineTests):
  1. Use a 3-chunk source.
  2. In the `progress` callback, on the second call, open `<dest>.partial` by path and `pwrite` one flipped byte at offset 0.
  3. Expect `throws: .verifyMismatch`, no destination and no partial.

  Add a second case: pre-create `<dest>.partial`, then expect `throws: .partialExists(…)` and the planted partial's bytes unchanged.

### N1008-T-Archive-F2 — P2 · REAL · Reconcile's "confirm the digest before indexing" refusal is unpinned
- **Symbol:** `PromoteToArchiveJob.reconcileJournal`, Archive/PromoteToArchiveJob+Steps.swift:182 (`guard let expected, actual == expected`).
- **Tests checked:** `crashAfterRenameConverges` and `manifestOnlyRowAdopted` (MasterArchivePromoteTests), `reconcileUndatedPlacementWins` (PromoteDatesAndLockTests) and Hardening 4b/5/7. Every one plants a file whose bytes equal the source's, so the guard is always true there.
- **Regression that would ship undetected:** the guard is loosened, for example to `guard let expected` alone, or to trusting the journal's sha when the rehash fails. A journaled destination holding different bytes then gets a manifest row and a catalog link as the source's archive copy. Examples of different bytes: a truncated copy from a power cut on an older build, or a file someone dropped into the year folder by hand. The source then counts as safely archived.
- **Smallest test:**
  1. Journal a `renamed` entry with `sha256 = sha(source)` for record S.
  2. Plant a same-size file with different bytes at that relpath.
  3. Run Promote with S in the plan.
  4. Assert: no manifest row has the planted relpath; `masterArchiveCopy(of: S)?.fullPath` is not the planted path; the planted file's bytes are unchanged.

  Add a second case: `intent` with no sha and the source present.

### N1008-T-Archive-F3 — P3 · REAL · Two Update… preflight refusals have no test
- **Symbol:** `ArchiveRefileEngine.preflight`, Archive/ArchiveRefile.swift:463 ("the archive manifest already lists a file at …") and :455 ("… with N different fingerprints").
- **Why nothing catches it:**
  - `targetExists` puts a file on disk, so `targetRefusal` (:480) refuses before :463 matters.
  - No test appends a second manifest row at the target, or a second row with another digest at `from`. Neither message string appears in any test.
  - C02-F7's proposed test covers only the case-variant path, not the exact-match line.
- **Regression that would ship undetected:**
  - **:463 deleted:** a stale row whose file is gone lets Update move a different file onto its path. Two manifest rows then name one file, and Verify reports a false mismatch for the stale one.
  - **:455 deleted:** Update moves a file under whichever of two conflicting digests happens to be last.
- **Smallest test** (ArchiveUpdateTests, `UpdateFixture`). Two cases:
  1. Append a manifest row at the planned `toRelPath`, with no file there.
  2. Append a second row at `from` with another sha.

  For each, expect `.refused`, the file still at `from`, and the manifest byte-identical.

### N1008-T-Archive-F4 — P3 · REAL · The manifest header check on the append path is pinned only through `validate`
- **Symbol:** `ArchiveManifestCSV.append`, Archive/MasterArchive.swift:783 (`expectedHeaders:` on `openIndexFile`, whose parameter defaults to `nil`, ArchivePromoteEngine.swift:743).
- **Tests checked:** MasterArchiveHardeningTests 3c and ArchiveReadinessTests write a header-less manifest, but they call only `validate`. 3b covers a symlink, not a header.
- **Regression that would ship undetected:** `expectedHeaders:` is dropped from `append` alone, for example in a refactor that shares an "open for append" helper. If the manifest is replaced between preflight and append, a row is then appended to a foreign or header-less CSV. `ArchiveDigestIndex` and Verify refuse that whole file, so GH #190 duplicate detection goes blind.
- **Smallest test:**
  1. Initialize, then overwrite the manifest with `not,a,header\n`.
  2. `#expect(throws: ArchivePromoteEngine.Failure.self) { try ArchiveManifestCSV.append(row, rootPath:) }`.
  3. Check the file is still exactly `not,a,header\n`.

### N1008-T-Archive-F5 — P3 · REAL · Reconcile's crash-leftover partial cleanup has no test
- **Symbol:** `PromoteToArchiveJob.reconcileJournal`, Archive/PromoteToArchiveJob+Steps.swift:163-167.
- **Tests checked:** no test plants an `intent` together with a `.partial` and no final file. `abandoned` is asserted nowhere; Hardening R4-A checks only that escaping entries are *not* advanced.
- **Regression that would ship undetected:** the cleanup is dropped or mis-gated. A crash mid-copy then leaves multi-GB `.partial` files in the archive for good, and the journal intent is never closed, so the entry is re-examined on every run. `chooseDestination` treats the partial as taken, so retries land at `_02`.
- **Note:** C02-F1's fix (skip sources owned by a live job) must keep this test green.
- **Smallest test:**
  1. Journal `intent` for record S.
  2. Create `<dest>.partial` (regular file), with no `<dest>`.
  3. Run a Promote with an empty plan.
  4. Assert the partial is gone and `latestBySource[S]?.state == .abandoned`.

### N1008-T-Archive-F6 — P3 · REAL · Read-only marked FOLDER: "place unknown → refuse" is unpinned
- **Symbol:** `ReadOnlyVolumeProtection.verdictAtRemoval`, Archive/ReadOnlyVolumeProtection.swift:304 (`guard let place else { return .readOnly(entry.label) }`).
- **Tests checked:** the folder tests (`aMarkedFolderProtectsTheFolderOnly`, codex258 `aMarkedFolderIsFoundByIdentityAtRemovalBeforeTheRebuildLands`) always supply an `identity` that resolves the path. Round4 r5e is a whole-drive mark.
- **Regression that would ship undetected:** `return .readOnly` becomes `continue`, a natural "be less strict" edit. A file in a marked folder, on the marked drive (UUID matches) but whose mount identity cannot be read at removal time, is then cleared for Delete Duplicates or junk removal.
- **Smallest test:**
  1. Make a provisional mark on a folder of drive U.
  2. Call `verdictAtRemoval` for a file inside that folder, under a renamed mount, with `probe` returning U and `identity` returning nil.
  3. Expect a non-nil verdict.

### N1008-T-Archive-F7 — P3 · REAL · The unlock refusal can be bypassed without any sensor noticing
- **Symbol:** `ArchiveFileLock.liveApply` / `Seams.live.apply`, Archive/ArchiveFileLock.swift:90, :127. Both are `static` and callable from anywhere. The refusal lives only in `set` (:103).
- **Why nothing catches it:** the sensors check three things:
  - `fchflags(` appears only in ArchiveFileLock.swift;
  - every `ArchiveFileLock.set(` caller is in the inventory;
  - `set(.unlock` and `.updateUnlock` appear only in ArchiveRefile.swift.

  A new call `ArchiveFileLock.liveApply(root:relPath:change: .unlock)`, or `ArchiveFileLock.Seams.live.apply(…, .unlock)`, from any other file passes all three. Today there is no such caller (grep).
- **Regression that would ship undetected:** a convenience "fix permissions" or repair path clears UF_IMMUTABLE on archived files, with no audit line.
- **Smallest test:** a source sensor in ArchiveLockUpdateAndJobTests. On code lines, `liveApply(` and `Seams.live` must occur in ArchiveFileLock.swift only.

### N1008-T-Archive-F8 — P3 · REAL · A late-attestation Update test can pass vacuously
- **Symbol:** ArchiveUpdateSafetyTests › `journalLineAfterPreparationIsNotLeftStale` (ArchiveUpdateSafetyTests.swift:105).
- **How it goes vacuous:**
  1. The injected late line is written with `try? ArchiveAttestationJournal.append(…)`.
  2. The journal is read with `UpdateFixture.data`, which returns empty `Data` for a missing file (ArchiveUpdateTests.swift:68).
  3. If the append fails, for example because a future change holds `ArchiveIndexLock` across `afterPreflight`, which would make the append `Busy`, no late line exists.
  4. `r.kind == .updated` plus `!journal.contains(old)` then passes. The test stops testing anything.
- **Fix:**
  - Capture the append error in a box and `#expect(error == nil)`.
  - In the `.updated` branch, also `#expect(journal.contains(<new path>))`.

### N1008-T-Archive-F9 — P3 · REAL · The only test for the 10-05 Archive-tab "Make a Copy" menu cannot fail on a logic regression
- **Symbol:** ArchiveTimelineMenuLayoutTests › `archiveViewLaysOutWithTheFollowUpMenus` (:31, :37). The feature is `ArchiveView+Table.swift` card menu (13b9c206).
- **Why it can't fail:**
  - The promote result is discarded (`_ = await …promote`). If promotion fails, there are no archived cards, so the new `!pfNotYetArchived` branch is never reached.
  - `#expect(host.fittingSize.width >= 0)` cannot fail.
  - The test is a crash sensor by design, and the commit says so. Whether a SwiftUI `contextMenu` body is built by layout at all is a Mac question.
- **Missing logic test:** nothing checks that the submenu is offered for exactly one archived record and disabled when its drive is unreachable.
- **Data-adjacent detail:** the Make-a-Copy sheet defaults its output folder to the archive copy's own year folder (TranscodeSheet `defaultToArchiveYearFolder`, a pre-existing Rick ruling 2026-08-25). That makes this a derivative written into the archive tree. The Replace path is guarded (`existingFilePolicy` → `bulkDeleteRefusal`), but the new entry point has no test of that guard.
- **Fix:**
  1. `let job = try #require(await …promote(…)); guard case .finished = job.state else { Issue.record(…); return }`.
  2. `#expect(model.records.filter(model.isArchiveCopy).count == 3)`.
  3. Add a model-level test that `TranscodeJob.existingFilePolicy` keeps (never trashes) an existing archived file at the output name when Replace is chosen.

### N1008-T-Archive-F10 — P3 · NOISE · The count sensors strip only whole-line `//` comments
- **Symbol:** `ArchiveUpdateSensorTests.code` (ArchiveUpdateSensorTests.swift:27) and `ArchiveVolumeProtectionSourceSensor.scan` (ArchiveVolumeProtectionTests.swift:707).
- **The gap:** a trailing `// … ArchiveIndexLock.withExclusive(` on a code line, or a `/* */` block, counts as a call. `everyIndexWriterHoldsTheLock` also pins counts per file, not that `appendDurable` sits *inside* the lock closure.
- **Why NOISE:** it needs a deliberate or very unlucky edit, and the behavioural lock tests (row 12) back it up.
- **Cheap hardening:** switch both to `SourceTree.strippingComments`, which already exists and is tested in DeleteDuplicatesCodex258Round3Tests.

## Five-dimension check, recent Archive features (09-29 → 10-06)

Key: ✓ = covered; — = not applicable; ✗ = missing.

| Feature (commit) | Logic | Scale 100k + budget | Media matrix | Isolation / poisoned | Sensor | Gap |
|---|---|---|---|---|---|---|
| Read-only drive mark + codex #258 fixes (ce16f2f1, 67cf95d1, 84e31c12, a876bdbe) | ✓ ReadOnlyVolumeTests | ✓ "100k selection…" | — (no media opened) | ✓ gate suite (volume marked) | ✓ `theGateHasTheReadOnlyHalf…`, codex258 `theFixesAreWhereTheyMustBe` | one branch (F6) |
| GH #190 duplicate refusal / GH #219 date agreement (3b690ce5) | ✓ | ✓ 100k index + 100k sensor | ✓ container matrix | ✓ poisoned index, per-root claims | ✓ | none |
| Adoption proves current bytes (c404771f) | ✓ PromoteAdoptionProofTests | — | ✗ (hashing is container-agnostic; low value) | ✓ lying stored digest | ✗ no production-scale sensor | minor |
| Source changed under copy rolls back fully (1ab2274f) | ✓ PromoteRefusalRollbackTests | — | — | — | ✗ | minor |
| Verify date sensor + bounded log line (18f6905d, 3324cb95) | ✓ | ✓ 50k-line bound; 100k sensor in PromoteArchiveIntegrityRuleTests | — | — | ✓ | none |
| Log privacy (d7420941) | ✓ ArchiveLogPrivacyTests | — | — | — | ✓ | none |
| Designation stays set (2e37a683) | ✓ MasterArchiveDesignationGuardTests | ✓ | — | ✓ | ✓ | none |
| Progress / needs-date off main (f9181d4) | ✓ ArchiveOffMainTests | ✓ 100k | — | — | ✓ | none |
| `DeviceID.from` (9783f286) | ✓ Core DeviceIDTests | — | — | — | ✓ st_dev sensor | none |
| Archive-tab Make a Copy / People tab (13b9c206) | ✗ | — | ✗ (a transcode of an archived file) | — | sensor is vacuous (F9) | F9 |
| Verify Archive Copies (pre-09-29) | ✓ | ✗ manifest parse is 10k, not 100k (`a 10k-row manifest parses…`) | ✓ "promote a real container…" | ✓ | ✓ | scale below the 100k bar (not raised as a finding: it predates the checklist window) |

## Not covered
- `MediaLedger`, `VideoScanModel+BackupAttestations`, `ArchiveLockJob` internals, `MasterArchiveReadoption`, `CopyFamilyAssessor`, `ArchiveItemVersions`, `ArchiveIndexRename` beyond the test list in CatalogRenameArchiveIndexTests.
- `BindFixityToVolumeJob` and `FixityRebind`: only the guard list and test names were checked. Coverage looks thorough: failed-save undo, compare-and-set, remount refusal.
- Verify's unmanifested and changed-under-Verify branches: the test names match the branches, but the assertions were not read.
- All SwiftUI views in Archive/.
- C02 findings are not repeated. None of C02-F1…F9 has a pinning test yet. F5 above is the closest neighbour of C02-F1, and C02-F2's short-write test is still unwritten.
- Nothing was built or run. Every test above is a sketch.
