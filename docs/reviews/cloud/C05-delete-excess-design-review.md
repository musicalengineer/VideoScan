Brief: C05 | Source: main@da39a05 (design doc 2026-10-06) | Wall clock: ~35 | Files read: 9
Finding count: 9 (REAL 8 / NEEDS-MAC 1 / NOISE 0)
Verdict: Tier 1's core rule ("read the copy now, Trash only, never trust a stored digest of the file being deleted") is right. But building the lane on PruneApply carries over guards whose premise is a person ticking copies one by one. Bulk select-all removes that premise, and with it the survivor rule, the bar, and every check on the archive's own bytes. Tier 2's acceptance rule contradicts the design's own keep rule.

## Scope

**Read in full:**
- `docs/design/delete_excess_copies_2026_10_06.md`

**Read to check the design's claims:**
- `MediaOps/VideoScanModel+PruneApply.swift`: header contract; `pruneSurvivorProblemNow` :395-399; fresh-plan holds :200-260
- `MediaOps/VideoScanModel+JunkDelete.swift` (`deleteConfirmedJunk`, read in full for N1007)
- `Archive/ArchiveVolumeProtection.verdictAtRemoval` :441-477
- `VideoScanCore/ContentFixity.describesFileNow` :290-301
- `MediaOps/RelocateReconcile.swift` and `Shared/FileHasher.swift` (from N1007, for the sampled-hash facts)

**Not opened:** `PruneApplyJob`, `DeleteDuplicatesFlow`, `CopyFamilyAssessor`, `+BackupAttestations` and `MasterArchive` (manifest). Their behaviour was taken from the design's own citations, which matched the parts of the code I did open. The N1011 report (PrunePlan guard inventory, same night) covers `PrunePlan`.

## What holds

- **Tier 1 proof:**
  - A copy *nominates* itself by `contentFixity` or `v1:`.
  - A delete needs a full read of the copy **now**, against the archive digest.
  - The stat-stamp re-check sits right before `trashItem` (`JunkDeletionGuard`).
  - Sampled hashes, partialMD5, names and footage groups never authorise a move (I4).
  - SHA-256 collisions and stale hashes on a rewritten copy are therefore covered.
- **The 29 drifted manifest rows:** joining on relpath + digest (Phase 0) is the right fix. Tier 1 compares against the archive record's `archiveFixity` and never trusts `record_id`.
- **Trash only (I5):** every mistake below stays recoverable until the drive's Trash is emptied. That is the biggest safety margin in the design, so §6's weekly empty-the-Trash reminder deserves a second thought (see F1).
- **Archive tree and archive volume** are refused by UUID at the removal boundary. Read-only drives are refused and still counted as survivors.

## Findings

### C05-F1 — P2 · REAL · "The archive copy is present and fixity-ok now" is a stat check, so the archive's bytes go unchecked exactly when the copy being trashed is the last other one
- **Symbols:**
  - design §3 "Delete-time proof" step 1
  - `ContentFixity.describesFileNow` — VideoScanCore/ContentFixity.swift:290-294 (size + ctime + volume, no read)
  - PruneApply header item 3 (`pruneArchiveVerdict`: "its stored stamp reproduces to the ctime, **or** it is read in full")
- **Scenario:**
  1. An archived master suffers silent media corruption since its last full verify. The RAID and APFS do not checksum file data, and a flipped sector does not change size, mtime or ctime.
  2. The bulk Tier 1 job reads the workspace copy in full. It matches the *stored* archive digest, because the copy is the good one.
  3. The archive's stamp reproduces, so the job trusts it unread, and the copy goes to the Trash.
  4. §6 already says many items will exist **only** on the RAID after Tier 1. Once Rick empties the Trash (prompted by the proposed weekly reminder), the only good copy is gone.
- **Why it matters:** this is the brief's "delete the ONLY good copy" case. The stamp proves the archive file was not *rewritten*; it does not prove its bytes are still good.
- **Pinning test (Phase 1 sensor):**
  1. Fixture: an archive file and a workspace copy with equal digests. The archive record's `archiveFixity` stamp is current.
  2. Corrupt one byte of the archive file with `pwrite`, then restore its mtime with `futimens`. ctime moves, so the test must use a seam that makes the stamp reproduce, as bit rot would.
  3. Run the lane on the copy. Expect `archiveUnverified` and nothing moved.
  4. Today's PruneApply path would trash it.
- **Fix direction:** when the copy being moved is the last copy outside the archive (the survivor-floor case), read the archive file in full **in this job**. That is once per item, not per copy. Record the read on `archiveFixity`.

### C05-F2 — P2 · REAL · PruneApply's survivor and bar guards assume a human ticked each copy; bulk select-all switches both off
- **Symbols:**
  - `VideoScanModel.pruneSurvivorProblemNow` — MediaOps/VideoScanModel+PruneApply.swift:395-396 (`guard !survivors.isEmpty else { return nil }`). Survivors are defined as *the copies the person left unchecked* (header §7, :92-114).
  - Bar overrides are **recorded, not refused** (header :10-16, `overrideCount`).
  - Design §4 ("the lane calls the PruneApply per-copy pipeline") and §6 decision 2.
- **Scenario:**
  1. The new lane's "Move N exact copies" passes every Tier 1 copy as checked.
  2. Nothing is left unchecked, so the survivor list is empty and `pruneSurvivorProblemNow` returns "go" at once. No floor is enforced at the move.
  3. A family that fails the bar (for example ★★★ with no cloud copy attested) is moved as an "override". The design's keep rule 5 and survivor floor (§6 decision 1) exist only in prose.
- **Why it matters:** PruneApply's own header states the premise: "the bar ADVISES; the person's checks are the truth". In a machine-built selection, nobody's checks are the truth.
- **Pinning test:**
  1. Run `applyPrune` with every copy of a family selected and the bar unmet.
  2. Expect the lane variant to refuse with "survivor floor", and a family whose bar fails to land in `refused`, not `overrideCount`.
  3. Today both go.
- **Fix direction:**
  - Give the lane an explicit `survivorFloor` and `keepRules` refusal step inside `pruneOneCopy` (run at selection and at the boundary).
  - Never reuse the override path for a machine selection.

### C05-F3 — P2 · REAL · Tier 2's "≥ 99% coverage" accepts a copy the design's own keep rule 6 says to keep
- **Symbol:** design §2 Tier 2b step 2 ("at least 99% of the *candidate's* duration must lie inside the master") against §3 keep rule 6 ("Longer: Tier 2 coverage of less than 100% of the candidate").
- **Scenario:**
  1. A 2-hour re-encode whose last 70 seconds (under 1%) are not in the archived master: a different tape tail, an extra goodbye, a scene the master capture missed.
  2. It passes 2b and is offered as excess with a bound proof.
  3. Seventy seconds of unique family footage go to the Trash.
- **Pinning test (Phase 2 fixture list):**
  1. A candidate = master excerpt plus 1% of different footage at the end.
  2. Expect refused ("adds footage the archive lacks").
- **Fix direction:**
  - Coverage is a hard 100% of the candidate's content, minus explicitly allowed slack: black, bars, or silence at the very ends, detected and named.
  - The proof stores the uncovered spans so the card can show them.

### C05-F4 — P2 · REAL · Sampled frame and barcode proof gives false "contained" verdicts on exactly the footage this archive holds
- **Symbol:** design §2 Tier 2b steps 1–2 (an offset from Spectrum's `slide()`, then "N decoded frames … perceptual hash … both must pass").
- **False-positive classes:**
  1. **Low-information frames:** black, colour bars, blue screen, title cards and still photos (slideshows) match at almost any offset, so N samples landing there prove nothing.
  2. **Repeated content:** a barcode cross-correlation can lock onto a wrong offset in footage with repeated scenes, such as the same room, re-shoots of the same event, or a tape that was dubbed twice.
  3. **Same tape, two captures:** two captures of the same tape with different trims *are* contained, but they can differ in local dropouts or tracking glitches. N perceptual samples miss a 3-second glitch in the master that the candidate captured cleanly. The design's quality guard covers pixels, bit depth and channels, not damage.
- **Pinning test:** add three fixtures to Phase 2:
  1. different footage that shares long black and bars sections, expecting **refused**;
  2. one source with a repeated scene where the true offset differs from the barcode peak, expecting refused or the correct offset;
  3. a master with a corrupted 2-second span against a clean candidate, expecting refused (the candidate is the better copy there).
- **Fix direction:**
  - Prove over **dense, contiguous windows** covering 100% of the candidate (for example every second), not N samples.
  - Drop low-entropy frames from the evidence; they count as neither pass nor fail.
  - Require continuous audio alignment.
  - Reject when any window's match score falls below the threshold, and store the per-window scores.

### C05-F5 — P2 · REAL · The archive's backup drives look exactly like Tier 1 excess, and the stop-gap detector misses common backup shapes
- **Symbols:** design §3 keep rule 2 ("Until the mark exists, the lane refuses every drive that holds … the manifest file name"); §6 (the 11/1 off-site copy); §6 decision 1(b), which counts attested backups as the survivor floor.
- **Scenario:**
  1. The 11/1 off-site copy, or any backup made by copying only the media folders (no `00_Index`), is connected and scanned.
  2. Every file on it is byte-identical to an archive file, so the whole drive is "Tier 1 proven".
  3. The manifest-name heuristic does not fire, and the volume mark does not exist yet (it is built in Phase 1 step 2, after the lane).
  4. Select-all trashes the archive's backup. Under decision 1(b), that backup was the very thing that made deleting the other copies acceptable.
- **Pinning test:**
  1. A synthetic drive holding archive-relative copies of archived files, without `00_Index`.
  2. Expect the forecast to list the whole drive as "left alone: looks like an archive backup".
- **Fix direction:**
  - Ship the *Archive backup* volume mark **before** the bulk action.
  - Detect structurally: a drive where most files match archive files by digest **and** archive relpath is refused until Rick classifies it.
  - Default to Tier 1 only on drives Rick has marked as workspace drives.

### C05-F6 — P2 · NEEDS-MAC · A network share of the archive volume is cleared by the protection, so "a copy that IS the archive file, reached by another path" passes Tier 1 trivially
- **Symbol:** `ArchiveVolumeProtection.verdictAtRemoval` — Archive/ArchiveVolumeProtection.swift:457-468. When the file's volume UUID can't be read, a network mount is `.clear`, on the comment's premise that it is "PROVABLY another volume".
- **Why that premise fails:** a share can be the archive volume exported by the other Mac.
- **Scenario:**
  1. The archive RAID is attached to one Mac and shared over SMB.
  2. The share is mounted and scanned as a target on the master catalog, for example during a two-Mac period.
  3. The share's paths carry the archive files' digests, so the read "matches".
  4. Neither the archive-tree path check nor the UUID check refuses them.
  5. If `trashItem` succeeds on that server (it does on SMB shares with a `.Trashes`), the archive file itself moves to the share's Trash.
- **Why NEEDS-MAC:** whether `trashItem` succeeds on SMB, and whether a share has a readable volume UUID, needs checking on a real Mac.
- **Pinning test:** feed `verdictAtRemoval` a path whose probe returns nil UUID and `isNetworkMount == true`. Expect the delete-excess lane to refuse, with a lane-level "network volume" refusal.
- **Fix direction:** the excess lane refuses network-mounted candidates outright. Excess on a share is rare and can go through Delete Duplicates' stricter survivor rules.

### C05-F7 — P3 · REAL · The forecast's plan and the run's plan answer "is this excess?" differently
- **Symbols:**
  - design §5 Phase 1 step 2 (a new catalog-wide `ExcessCopiesPlan`, nominated by digest)
  - the run re-derives eligibility from `PrunePlan` inside `pruneOneCopy`: copies the fresh `PrunePlan` does not offer are held as "was never offered" (MediaOps/VideoScanModel+PruneApply.swift:200-215)
  - `PrunePlan` families are keyed by content + provenance (`ArchiveCopyFamilies.group`) and exclude pair members
- **Scenario:**
  1. A digest-equal copy with no promote link to the archived item, or an A/V pair member, is counted by the forecast ("Move 51 copies, 638 GB").
  2. The run holds it as "never offered".
  3. The big click does less than it said, and the rest gets reported as refusals. This is the C01-F1 class: two plans, one question.
- **Pinning test:** for a fixture catalog, expect the set nominated by the `ExcessCopiesPlan` forecast to equal the set the run's fresh plan accepts.
- **Fix direction:** one plan object, used by both the forecast and `pruneOneCopy`. Either extend `PrunePlan`, or make `pruneOneCopy` take the lane's plan.

### C05-F8 — P3 · REAL · Survivor floor (b) rests on attestations that are "remembered, never checked" and do not say which copy they describe
- **Symbols:** design §6 decision 1(b); `BackupAttestation` (per record, cloud / offsite / drive × yes / no / n/a; design §1.9).
- **Scenario:**
  1. The "cloud: yes" answer was given on the *workspace* record, meaning "this tape's lower-resolution upload is in the cloud".
  2. Promote copied it onto the archive record (attestations ride the promote).
  3. Option (b) now counts it as the archive item's off-site backup.
  4. Tier 1 deletes the last full-resolution copy outside the RAID.
- **Pinning test:** an archive record whose only attestation was inherited at promote. Expect the floor to treat it as "unverified backup" and to refuse when the floor is (b).
- **Fix direction:**
  - (b) needs an attestation made *on the archived item, about the archive set*, dated after promote.
  - Better still, a checked off-site copy (a drive with the backup mark, F5) whose digests were read.

### C05-F9 — P3 · REAL · The measurement counts files the keep rules will always refuse, so Phase 1's reconciliation can't match
- **Symbol:** design §0, per-drive table row "FamilyArchive (outside the root)": 0.1 GB T1 + 4 GB T1c + 9 GB T2. Keep rule 1 refuses the archive **volume** by UUID (`.archiveVolume`).
- **Scenario:**
  1. Phase 1 step 3 asks for the forecast total to reconcile with "this doc's 1.33 TB".
  2. The forecast will always show the archive-volume files as left alone, so the numbers differ by design.
  3. Someone may then "fix" the forecast or the protection to make them agree.
- **Pinning test:** none needed. Correct the doc's baseline to exclude archive-volume files, and say so.

## Answers to the brief's questions, in one line each
1. **Only good copy:** yes, through a rotted archive file trusted by its stamp (F1), a backup drive taken for excess (F5), or the archive itself reached over a share (F6).
2. **Keep rules:** they are named, but enforced only in prose. PruneApply turns the bar into an override and has no floor under select-all (F2). Angel holds are a known gap (Phase 0 covers it).
3. **PruneApply as engine:** right for Tier 1 *if* the lane adds an explicit floor, keep-rule refusals, a full archive read for last-copy cases and one shared plan (F1, F2, F7).
4. **Tier 2 proof:** dense windows covering 100% of the candidate, low-entropy frames excluded, continuous audio, a damage check (F3, F4).
5. **Bulk UX:** the forecast and the run disagree (F7). Drives changing and drives going offline are handled at the boundary, and offline means keep.

## Not covered
- The Delete Duplicates engine alternative, in depth (§6 decision 2). The F2 issues do not arise there, because Delete Duplicates has its own survivor rule.
- Phase 2 performance: dense windows cost decode time; I have not estimated it.
- Nothing was built or run. All tests are sketches for the Phase 1 and 2 "tests first" lists.
