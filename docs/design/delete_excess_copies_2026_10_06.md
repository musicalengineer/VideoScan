# Delete excess copies of archived footage — design study

*2026-10-06 · status: DESIGN, no app code · data-risk (safety-critical mode)*

**The workflow, in Rick's words:** "Once the whole master FFV1, access,
editable is in the archive, review and delete all the rest, in bulk, not
one video at a time."

**KEEP** means the archived set for an item: everything under the Master
Archive root on the RAID (preservation FFV1, access HEVC, editable ProRes,
and the byte-for-byte original where one was filed). **EXCESS** means any
other file that is the same footage. This doc measures how much excess
there is, maps what already exists, and proposes the smallest design that
lets Rick clear it in bulk with confidence.

Privacy: no family names or paths below. Items are labelled `Item-NNN
(decade)`. The private label map stays in the session scratchpad.

---

## 0. Measured on the real catalog (read-only, 2026-10-06)

The script (`measure_excess.py`, session scratchpad, not in git) read
`~/Library/Application Support/VideoScan/catalog.json` (generation 3018)
and `<archive root>/00_Index/Archive_Inventory_Manifest.csv`. It opened
nothing else: no stat, no media reads. "Live" means not Trashed, Deleted
or purged.

| | Files | Bytes | % of catalog |
|---|---:|---:|---:|
| Live catalog, total | 12,179 | **8.99 TB** | 100% |
| Inside the Master Archive root (KEEP) | 164 | 3.04 TB | 33.7% |
| Everything else | 12,015 | 5.96 TB | 66.3% |
| **Tier 1, proven**: whole-file SHA-256 (`contentFixity`) equals an archived file's digest | 25 | **693 GB** | 7.7% |
| **Tier 1, candidate**: segmented `v1:` hash and size equal an archived file's (a full read is still needed) | 51 | **638 GB** | 7.1% |
| **Tier 2 candidates**: linked to an archived item, bytes differ or are unproven | 60 | **558 GB** | 6.2% |
| **All archive-linked excess** | 136 | **1.89 TB** | 21.0% |

**What "hash" means here.** The catalog's `contentHash` is
`FileHasher.segmentedHash`: SHA-256 over three 1 MiB windows plus the file
size (`Shared/FileHasher.swift:127`). It can prove two files *different*
but never the *same* (header :41-53, codex #320). The only whole-file
digests in the catalog are:

- `contentFixity`, plain SHA-256, stamp-bound (`Archive/VideoScanModel+MasterArchive.swift:1178`). 1,819 non-archive records have one.
- `archiveFixity` on archive copies (139 of 164).
- The manifest's `sha256` column (143 rows).

All three use the same digest, so they compare directly.

**Tier 2 by kind of proof:**

| Proof | Files | Bytes |
|---|---:|---:|
| Lineage (`derivedFrom` / promotion source) | 12 | 262 GB |
| Footage group "likely" | 38 | 200 GB |
| Footage group "possible" | 6 | 67 GB |
| Duplicate group (High/Medium), direct or through the promotion source | 3 | 9 GB |
| partialMD5 + size only (weak) | 1 | 20 GB |

Of the promotion sources (`derivedFrom` lineage), 22 files (~285 GB) carry
bytes equal to an archive file by `contentFixity` or `v1:`, so they already
counted as Tier 1. The other **8 files (146 GB) differ from their archive
copy**. They are "restored" or "balanced" lineage, where the archive holds
a *changed* version. They are not excess unless Rick says so.

**Per drive (GB):**

| Drive | T1 proven | T1 candidate | T2 |
|---|---:|---:|---:|
| MediaExpansion | 590 | 138 | 72 |
| LaCieWorkspace | 78 | 236 | 61 |
| SanDiskWorkspace | 26 | 56 | 134 |
| CrucialX10 | — | 92 | 115 |
| Projects | — | 104 | 76 |
| CrucialX9 | — | — | 73 |
| M4drive | — | 7 | 18 |
| FamilyArchive (outside the root) | 0.1 | 4 | 9 |

**Top items by excess bytes, per drive** (top 5 of 15 shown; the full list
is in the scratchpad report):

- **MediaExpansion** (a VHS-conversion folder; one 40–75 GB original per tape):
  - Item-043 (1990s): 1 copy, 73 GB, T1
  - Item-104 (2020s): 1 copy, 71 GB, T1c
  - Item-042 (1990s): 1 copy, 69 GB, T1
  - Item-032 (1990s): 1 copy, 64 GB, T1
  - Item-039 (1990s): 1 copy, 63 GB, T1c
- **LaCieWorkspace:**
  - Item-100 (2010s): 1 copy, 54 GB, T1c
  - Item-056 (1990s): 3 copies, 39 GB, T1c
  - Item-048 (1990s): 1 copy, 37 GB, T1
  - Item-001 (1940s): 1 copy, 22 GB, T1c
  - Item-104 (2020s): 1 copy, 19 GB, T2
- **SanDiskWorkspace:**
  - Item-043 (1990s): 1 copy, 46 GB, T2
  - Item-046 (1990s): 1 copy, 31 GB, T2
  - Item-054 (1990s): 2 copies, 27 GB, T1 + T2
  - Item-084 (2000s): 2 copies, 26 GB, T1c + T2
  - Item-020 (1990s): 2 copies, 21 GB, T1c
- **CrucialX10:**
  - Item-038 (1990s): 62 GB, T1c
  - Item-034 (1990s): 47 GB, T2
  - Item-053 (1990s): 30 GB, T1c
  - Item-112 (1990s): 30 GB, T2
  - Item-015 (1980s): 20 GB, T2

Excess is a few very large files per item, not many small ones. 136 files
make up 1.89 TB, about 14 GB a file. "7 copies, 42 GB" is not the shape;
"1 copy, 70 GB" is. A card per *occasion* is still the right unit (§4),
but the count of files per card is small.

**Where Rick's "40% copies" comes from.** Archive-linked excess is 21% of
the catalog. Another **~1.9 TB** (4,869 groups) is extra copies of
footage *not yet archived*: files whose `v1:` hash and size match another
non-archive file. That pile belongs to Delete Duplicates, not to this
lane. Together the two are ~3.8 TB, about 42%, which matches Rick's
estimate.

**Gaps found:**

1. **811 non-archive records (960 GB) have no `contentHash`.** They cannot
   reach Tier 1 until the hash backfill covers them
   (`Media/VideoScanModel+ContentHashBackfill.swift`).
2. **Manifest/catalog id drift.** 29 of 143 manifest rows carry a
   `record_id` that is no longer the catalog id of the archive record at
   that path. All 29 resolve by `archive_relpath`, and their SHA-256 still
   matches. Any design that joins on the manifest must join on
   relpath + digest, not `record_id`. File this as a bug.
3. **Offline drives:** none. All 8 catalog volumes were mounted at
   measurement time. The design still has to treat offline as "leave
   alone".
4. **Holds and stars:** none of the Tier 1 rows has a star rating ≥ 4.
   43 tiered rows carry a "yes" cloud/offsite attestation; see §3.
5. **Cross-check still to do:** Tidy already computes "Copies of archived
   media — N outside the Master Archive" (`Catalog/TidyCatalogSheet.swift:78`,
   from `PrunePlan`). Phase 1 must reconcile that number against this one.

---

## 1. What exists and how it fits

Read this section first. **Most of the machinery is already built.**

### 1.1 "Archived — what next?" and PruneApply

This is already the delete-copies-of-archived-media path.

- `Archive/ArchivedWhatNextSheet.swift:68` shows a per-family checklist of
  working copies. Archive copies are never rows, and only a *verified*
  archive makes a family checkable. `runApply` (:405) calls
  `startPruneApply` (`MediaOps/PruneApplyJob.swift:645`).
- `MediaOps/VideoScanModel+PruneApply.swift:625` `pruneOneCopy` runs, per
  copy:
  1. a fresh plan;
  2. `bulkDeleteRefusal`;
  3. archive evidence: `pruneArchiveVerdict`
     (`MediaOps/VideoScanModel+PruneVerification.swift:121`). Either the
     stored stamp reproduces, or the archive file is read in full;
  4. a byte-for-byte read of the copy against the archive digest;
  5. note carry-over;
  6. **Trash only**, through `deleteConfirmedJunk`.
- Families come from `ArchiveCopyFamilies.group` (VideoScanCore
  `PrunePlan.swift:450`), keyed by content plus provenance. Tidy → "Copies
  of archived media" opens it for the backlog.
- **Gap:** PruneApply does not check Archive Angel holds (§1.4).

### 1.2 Delete Duplicates

- **Front door:** `MediaOps/DeleteDuplicatesFlow.swift:29`. It runs the
  picker, then `prepareConfirmation` (:98, which builds the forecast), then
  the destructive alert, then `startDeleteDuplicates`. The Storage card
  (`Volumes/StorageReclaimableCard.swift:100`) and the Steward
  (`Steward/StewardPaneView.swift:121`) host it.
- **A third, private copy** of picker + alert + start remains in
  `App/ContentView.swift:1048-1054`. So "one front door" is not quite true
  today.
- **Scope:** one volume. It only handles rows with
  `duplicateDisposition == .extraCopy` in a byte-identical duplicate group
  (`MediaOps/VideoScanModel+Duplicates.swift:1117/1142`).
- **Survivor rules:** `MediaOps/DeleteDuplicatesPlan.swift:551`.
  - ≥ 2 verified copies → Trash.
  - Permanent delete only when `n >= 3 && (distinctDrives >= 2 || countsArchiveCopy)` (:579).
  - `recheck()` (:469) re-stats every counted copy at the removal boundary.
- **Drives:** physical devices, keyed by DiskArbitration
  (`MediaOps/DeleteDuplicatesDrives.swift:99`).
- **Keeper:** the Master Archive copy always wins the keeper election
  (`MediaOps/DuplicateKeeperPolicy.swift:242`).
- **Proof:** the file being deleted is always read in full, after it is
  moved into quarantine. `contentHash` and `partialMD5` never authorise a
  delete (`MediaOps/DeleteDuplicatesJob.swift:25, 332-346`).
  `removalBoundary` (:1587) re-asks three things right before the unlink
  or Trash: the hold, Read-only marks, and today's archive designation.

### 1.3 Confirmed junk and ⌘⌫

- `MediaOps/VideoScanModel+JunkDelete.swift:161` `deleteConfirmedJunk` is
  the one Trash routine. ⌘⌫ (`Catalog/CatalogTrashCommand.swift`) and
  PruneApply both use it.
- It re-checks `bulkDeleteRefusal` per file (:326).
- It does no verification and no copy count, by design: junk is junk.

### 1.4 Protection and holds

- **One gate:** `bulkDeleteRefusal`
  (`Archive/VideoScanModel+MasterArchive.swift:746`, cases at :705). It
  covers the archive tree, the archive volume (by UUID, not path spelling:
  `Archive/ArchiveVolumeProtection.swift:79`), and read-only drives
  (`Archive/ReadOnlyVolumeProtection.swift:70`). Read-only files still
  count as survivors.
- **Angel holds** are derived live, never stored:
  `duplicateAngelUseRule()` (`MediaOps/VideoScanModel+Duplicates.swift:323`).
  A record is held while it is prepared, promoted-but-buffered, handed
  over, or in a running prepare. Delete Duplicates checks holds at
  selection, after the read, and at the removal boundary. The Steward and
  the Reclaimable card use them too. **Junk delete and PruneApply do not.**

### 1.5 Content Steward

- `Steward/StewardCase.swift:26` defines the case kinds: event,
  unlabelledDay, reclaimDrive, reclaimGroup, sameFootage, junk.
- `StewardProtection` (:86) explains why a file is safe.
- The builder (`Steward/StewardCaseBuilder.swift:208`) runs in a detached
  task (`Steward/VideoScanModel+Steward.swift:177`).
- **The Steward has no delete of its own.** Its delete button opens the
  shared flow (`Steward/StewardPaneView.swift:366`). This is the pattern
  to copy.

### 1.6 Footage groups and Find Similar Footage

- Confidence levels: identical > confirmed > likely > possible
  (VideoScanCore `FootageMembership.swift:34`). **identical** means both
  whole-file SHA-256s match *and* each stamp still describes its file
  (`FootageGroups/FootageGrouping.swift:158-183`).
- Link reasons map to confidence:
  - lineage, name+duration and sampled signature → **likely**;
  - "person said same" → **confirmed**.
- Roles include copy, reEncode, transcode, export, trim, restored and avHalf.

### 1.7 Footage Spectrum (#260)

- `MediaOps/FootageSpectrum*.swift` runs `scripts/footage_spectrum.py`.
- It builds a colour-over-time barcode plus a sound band. `slide()`
  (py:397) finds the offset; `verdict()` (py:474) returns
  same / close / part / diff, with `share`, `ref_cov` and `offset`.
- **"part" is today's only excerpt (containment) signal.**
- Output is an HTML page only. Nothing goes back to the records, and the
  cache key is path + size + mtime, not content.
- The "prove at aligned offsets" step is **Stage 2, not built**
  (`docs/design/footage_spectrum_design_2026-10-03.md` §3.1, §7).

### 1.8 Other compare tools

- `MediaOps/PairCompareJob.swift` / `Media/MediaPairComparator.swift`
  compare whole spans only (32-frame dHash at matching positions), so they
  cannot see an excerpt.
- `MediaOps/TranscodeJob+FrameMD5.swift:56` `compareFrameMD5` does a
  bit-exact per-frame decode check. It is used today for FFV1 preservation
  only.

### 1.9 Archive helpers

- **`CopyFamilyAssessor`** (`Archive/CopyFamilyAssessor.swift:227`) picks
  what to *promote* (original vs repaired vs access …). It has no delete
  verdict. Use it read-only, for the role words on cards.
- **Reclaimable card** (`Analyze/AnalyzeReclaimable.swift:179`): duplicate
  groups only, with no archive notion. The Steward reuses it.
- **Backup attestations** (VideoScanCore `BackupAttestation.swift:57`):
  per-record answers of cloud / offsite / drive × yes / no / n/a.
  "Remembered, never checked." **There is no concept of a drive that is a
  backup of the archive volume.**
- **Fixity:** `Archive/VerifyArchiveCopiesJob.swift` is batch-only, but
  its pieces are reusable: `hashContainedOffMain` (:971) and the stat-only
  freshness check `ContentFixity.describesFileNow`.

**How it fits together.** The engine this lane needs (archive-verified,
byte-for-byte, Trash-only, per copy) is **PruneApply**. What is missing:

- a catalog-wide, per-drive, bulk front end;
- the Angel-hold check in PruneApply;
- an archive-backup-drive exclusion;
- a Tier 2 proof engine.

---

## 2. The three tiers and the proof each needs

| Tier | Claim | Proof that authorises a delete | Bulk? |
|---|---|---|---|
| **1. Exact** | This file *is* an archived file, byte for byte | Whole-file SHA-256 of **this file, read now**, equals the archived file's `archiveFixity` digest, and the archived file is verified present now (§3) | **Yes**, one action per drive or for everything |
| **2. Contained** | This file is a re-encode or excerpt of the archived master and adds nothing | A stored, versioned **containment proof** (below), reviewed per card, bulk-approvable per card | Per card, with side-by-side proof |
| **3. Similar** | Looks like the same occasion | None | **Never bulk.** Review and compare only |

### Tier 1

- The catalog's `v1:` match and `contentFixity` match are how a file
  *nominates* itself. They are not the proof.
- The proof is the read at delete time that PruneApply already does
  (`SignatureVerification.verifyAgainstStoredKeeper`).
- A stored `contentFixity` whose stamp still reproduces is enough for the
  **forecast** to say "proven". The delete still reads the file. Rule:
  *nothing destructive trusts a stored digest of the file being deleted*
  (DeleteDuplicatesJob header).

### Tier 2

There are two sub-kinds, with different proof strength.

- **2a. Lossless-equivalent.** The archive holds an FFV1 made from this
  exact source.
  - **Proof:** `compareFrameMD5` of the source against the FFV1, with all
    frames equal and the audio sample MD5 equal.
  - This is bit-exact decoded identity, which is as strong as Tier 1 for
    the picture.
  - Measured today, the FFV1 lineage sources already match their archive
    file by hash (Tier 1). 2a matters for future promotes where only the
    FFV1 is filed.
- **2b. Lossy re-encode or excerpt.**
  - **What exists:** Spectrum's `part` / `same` verdict with an offset.
  - **What is missing:**
    1. **Prove at the offset.** Take N decoded frames from the candidate at
       known times, and compare each against the master at time + offset
       with a perceptual hash (`Media/PerceptualHash.swift`). Also align
       the audio. Both must pass.
    2. **Coverage.** At least 99% of the *candidate's* duration must lie
       inside the master. A candidate that runs longer than the master is
       never excess.
    3. **Resolution and quality guard.** Refuse when the candidate has more
       pixels, a higher bit depth, or more audio channels than every
       archived version. It might be the better copy.
    4. **Write-back.** Store a `containmentProof` on the record:
       - master id and its digest;
       - offset, coverage and per-check scores;
       - algorithm version;
       - the stamps of both files.
       Any change to either file voids the proof, the same rule as
       `ContentFixity`.
    5. **Content-keyed cache** (digest, not path + mtime).
- **2c. Changed versions.** The archive holds a *changed* copy (balanced,
  restored or trimmed): 8 files, 146 GB measured. The source is **not
  excess by default**. Rick must say so per item.

### Tier 3

- Footage group "likely" or "possible" with no Tier 2 proof, a same-name
  hit, or the weak partialMD5-only match.
- Shown so Rick can open Compare. There is never a delete button on the
  card itself.

---

## 3. Keep rules, stated precisely

A file is **never** a delete candidate if any of these hold. Each check
runs at selection *and again at the removal boundary*, before the first
write.

1. **It is in the archive set.** The path is under the archive root, or
   it sits on the archive volume by UUID (`bulkDeleteRefusal`
   `.archiveTree` / `.archiveVolume` / `.archiveVolumeUnprovable`).
2. **It is on an archive backup drive.**
   - No such concept exists today. Per-record attestations are about
     "another copy exists elsewhere", not "this drive is the archive's
     backup".
   - **Proposal:** a volume-level mark, *Archive backup*, stored like
     `readOnlyMark` (by volume UUID). `bulkDeleteRefusal` refuses any file
     on a marked drive.
   - Until the mark exists, the lane refuses every drive that holds a
     folder tree mirroring the archive root's `00_Index`. Detection is
     cheap: look for the manifest file name.
3. **It is on a read-only drive** (`readOnlyMark`). It still counts as a
   surviving copy.
4. **The Archive Angel holds it** (`duplicateAngelUseRule`). PruneApply
   must gain this check. It is checked three times: at selection, after
   the read, and at the boundary.
5. **Rick holds it.** Star rating ≥ 4, a workflow tag of "keep", or a
   Steward "skip". The lane shows the reason; it never overrides.
6. **It is the last copy of anything the archive lacks:**
   - **Longer:** Tier 2 coverage of less than 100% of the candidate.
   - **Better:** the quality guard above.
   - **Paired:** an A/V half whose partner is not also covered.
7. **Its drive is offline, or its stamp cannot be taken.** Unknown means
   keep.

**Delete-time proof (per copy, in this order; any "no" refuses that copy
only):**

1. The archived counterpart is present and fixity-ok **now**. Either its
   `archiveFixity` stamp reproduces (stat-only, `describesFileNow`), or it
   is read in full and matches (`pruneArchiveVerdict`). Never on the
   strength of a past audit alone.
2. The copy is read in full and matches the archived digest (Tier 1), or
   its stored containment proof is still bound to both current stamps
   (Tier 2).
3. The keep rules re-run.
4. **Trash only** (`deleteConfirmedJunk(.toTrash)`). The catalog record
   keeps a note "excess copy of <archive relpath>, verified <time>".
   Permanent removal is Rick emptying the drive's Trash, by hand.

**Outcomes, each with a test, none reported as success unless it is:**

| Outcome | Meaning |
|---|---|
| `trashed` | The copy is in that drive's Trash; the record is marked; a ledger event is written |
| `refused(reason)` | A keep rule, a hold, read-only, offline, or a proof failure. **Nothing moved** |
| `archiveUnverified` | The archived counterpart is missing or mismatched. The whole item stops, and an alert names the archive file |
| `mixedState(where)` | The Trash move failed mid-way. The doc names where the file is |

Every one writes a START line and an OUTCOME line through the one sink to
the console, `catalog.log` and `videoscan.log`, plus a ledger event.

**Invariants for codex to attack:**

- **I1.** No file is moved unless an archived file with the same full
  digest (Tier 1) or a bound containment proof (Tier 2) was verified
  present *after* the job started.
- **I2.** No file under the archive root, on the archive volume, or on a
  backup-marked or read-only drive is ever moved.
- **I3.** A held file is never moved, even if the hold appears mid-job.
- **I4.** Sampled hashes, partialMD5, names and footage groups never
  authorise a move.
- **I5.** Nothing is unlinked. Trash only.

---

## 4. The Triage UI

**Where it goes.** A new lane in the Triage tab, beside the Steward
(`Catalog/TriageView.swift:379`). It could be a new `StewardCaseKind`,
`.excessCopies`, ordered between sameFootage and reclaim
(`Steward/StewardCase.swift:56`), or its own pane directly under :381.
**Recommendation: a Steward case kind.** That reuses the detached builder,
the skip store and the card chrome.

**The lane header (per-drive totals):**

> Delete excess copies — 1.33 TB of exact copies on 6 drives · 558 GB more to review
> MediaExpansion 728 GB · LaCie 314 GB · Projects 104 GB · …

**Occasion card** (one per archived item; the item fold is
`ArchiveItemVersions` + `derivedFrom`):

> **1995 occasion** (Item-043) — archived: master (FFV1) ✓ · access ✓ · editable ✓
> 2 copies, 119 GB, no longer needed — MediaExpansion (73 GB, exact) · SanDisk (46 GB, re-encode, proof below)

- Ticks show which archived roles exist and passed their last verify.
- A missing role (no access copy, say) is shown, not hidden. It is a
  promote task, not a reason to keep excess.

**The big action (Tier 1 only):**

1. **[Forecast exact copies…]** reads only the catalog and current stat
   stamps (seconds). It shows per drive:
   - would go to Trash;
   - needs a read first (GB and an estimated time);
   - left alone, with each reason (held, read-only, offline, archive not
     verified).
   This is the `DeleteDuplicatesForecast` shape.
2. **[Move N exact copies (X GB) to the Trash]** starts **one MFO job**:
   DELETE chip, "N of M", current file, time left, Pause/Stop, per-item
   detail on double-click.
3. It reads each copy once (1.33 TB at RAID/USB speeds is hours), so it
   is an overnight-able job with resume from a saved plan, like Delete
   Duplicates.

**Tier 2 cards** are reviewed per card, but approve in bulk per card:

- Side by side: the archived master's barcode strip over the copy's,
  aligned at the offset, plus 4–6 frame pairs at the checked times and
  the coverage percentage.
- Buttons: **[Move to Trash]** (enabled only with a bound proof) ·
  **[Keep]** (remembered) · **[Compare…]**.
- A **"Approve all proven re-encodes on this drive"** button appears only
  after Rick has approved, say, 10 individual Tier 2 cards without
  overriding one. That is confidence earned, not assumed.

**Tier 3** shows as a muted count ("12 look similar — review") that opens
the existing footage-group sheet. It never has a delete button.

**Every move goes through one front door.** Today there are two engines:
the DeleteDuplicates job and PruneApply. **Proposal:** the lane calls the
PruneApply per-copy pipeline (it is already archive-centred and
Trash-only), started through a thin `ExcessCopiesFlow` modifier shaped
exactly like `DeleteDuplicatesFlow`: picker, then forecast, then confirm,
then the MFO job. Also fold the private copy in `ContentView.swift:1048`
into the shared flow.

**SwiftUI note for Rick (C++ framing).** The card list is a value snapshot
built off-main (think: an immutable `std::vector<Card>` produced by a
worker thread and swapped in under a lock). The view body only renders
it; it never walks `records`. That is the "nothing O(records) in view
bodies" rule.

---

## 5. Phasing (tests first in each)

**Phase 0: fixes the measurement found (small)**

- Add the Angel-hold check to PruneApply, at selection and at the
  boundary.
- Join the manifest by relpath + digest, not `record_id`, and file the
  id-drift bug.
- Fold the ContentView delete-duplicates copy into the shared flow.
- Tests: a poisoned-hold isolation test, and a manifest id-drift fixture.

**Phase 1: Tier 1, the big hammer**

1. **Tests first:**
   - Logic: each keep rule refuses, and each outcome is named.
   - Scale: 100k synthetic records, with a budget for the forecast of
     ≤ 2 s and no main-thread walk.
   - Media matrix: Tier 1 move on mp4, mov/prores, mkv/ffv1, mxf, dv.
   - Isolation: a poisoned designation and a poisoned backup mark.
   - Sensors:
     - the archive file altered between forecast and move → `archiveUnverified`, nothing moved;
     - the copy altered → `refused`;
     - a hold added mid-job → `refused`.
   - Show each one red by mutation.
2. Build the catalog-wide `ExcessCopiesPlan`, the Steward case, the
   forecast and the MFO job on the PruneApply pipeline. Then build the
   Archive backup volume mark.
3. Reconcile the forecast total against Tidy's `archivedCopyBytes` and
   against this doc's 1.33 TB.
4. **Codex pass #1** (Rick triggers), scope:
   - `ExcessCopiesPlan`;
   - `pruneOneCopy` and `pruneArchiveVerdict`;
   - the `bulkDeleteRefusal` additions;
   - the flow.
   Invariants: I1–I5.
5. Rick's spot test: one drive first (MediaExpansion, 590 GB proven), then
   the rest.

**Phase 1b: hash backfill**

- Run the content-hash backfill over the 811 unhashed records (960 GB),
  then re-measure.

**Phase 2: Tier 2 proof engine**

1. **Tests first:** synthetic fixtures (an ffmpeg excerpt, an H.264
   re-encode, a longer cut, a higher-resolution copy, and different
   footage with the same barcode). Each must land in the right
   accept/refuse bucket.
2. Build Spectrum Stage 2: frame-level proof at the offset, coverage and
   the quality guard. Write back a versioned, stamp-bound
   `containmentProof`. FFV1 sources use `compareFrameMD5` (2a).
3. Build the Tier 2 cards with side-by-side proof.
4. **Codex pass #2**, scope: the proof engine and the write-back.
   Invariant: no accepted proof for a candidate that contains a frame or
   second not in the master.

**Phase 3**

- Earned bulk for Tier 2. Tier 3 stays review-only.

---

## 6. Risks and open questions for Rick

**Risks**

- **Trash does not free space.** 1.3 TB sits in per-drive Trashes until
  Rick empties them. The lane should show "in Trash on this drive: X GB"
  and remind him once a week.
- **Read cost.** Tier 1 reads every copy once: ~1.33 TB, several hours.
  Run it overnight on the M4, per the MFO rules.
- **The archive is the single survivor.** After Tier 1, many items exist
  **only** on the RAID until the 11/1 off-site copy lands.
  - Recommendation: Tier 1 deletes only for items whose archive copy also
    has an attested backup (cloud or offsite "yes"), **or** after 11/1.
  - Delete Duplicates' "3 copies on 2 drives" rule would otherwise refuse
    most of these.
- **Lossy ≠ excess when it is the better copy.** A 2010s re-encode can
  have cleaner audio than the archived master. The quality guard covers
  pixels, depth and channels, but not *taste*. That is why Tier 2 is per
  card.
- **Stale lifecycle labels.** 749 non-archive records read
  `lifecycleStage = Archived`, and many have `archiveStage = Manually
  Deleted`. The design keys only off digests and links, never these
  labels.

**Decisions for Rick**

1. **Survivor floor.** May Tier 1 leave the archive as the *only*
   remaining copy? Choose one:
   - (a) yes;
   - (b) only once the archive item has an attested off-site or cloud
     backup;
   - (c) wait for the 11/1 off-site copy.
   *Recommendation: (b) now, (a) after 11/1.*
2. **Engine and front door.** Build the lane on PruneApply ("Archived —
   what next?"), with a new `ExcessCopiesFlow` front door, and fold the
   stray ContentView copy into Delete Duplicates? Or force everything
   through the Delete Duplicates job?
   *Recommendation: PruneApply. It is already archive-centred.*
3. **Originals and changed versions.** Two parts:
   - Are pre-archive sources whose FFV1 proves frame-identical (2a)
     excess, when the archive keeps no byte-copy original?
   - Are sources of *changed* archive versions (balanced or restored:
     8 files, 146 GB) excess, or keepers?

**Smaller questions**

- Should "Archive backup drive" be a new volume mark, or reuse the
  read-only mark?
- Is the Tier 2 "earned bulk" threshold (10 approvals) right?
- Should the weekly empty-the-Trash reminder exist at all?

---

## Amendments after the adversarial review (cloud C05, verified by local qa 2026-10-07)

C05: `docs/reviews/cloud/C05-delete-excess-design-review.md`. 7 findings confirmed, 2 partly. These amendments override the body above.

1. **No override path (F2).** The bulk lane never uses PruneApply's "override" route (`PruneApply.swift:10-16`). A machine-built selection is REFUSED if it fails the bar, keep rule 5 or 6, or the survivor floor of decision 1. The floor is a step of its own at selection time AND again immediately before each move. "Nobody left unchecked" (`PruneApply.swift:396`) is never a pass for a machine selection.
2. **Read the archive bytes (F1).** When the copy being moved is the last copy outside the archive, read the archive file in full in this job (digest compare). A stamp that reproduces (`PruneVerification.swift:137-138`) is not enough at that moment.
3. **Backup drives first (F5).** The *Archive backup* volume mark ships BEFORE the bulk action. Until Rick classifies a drive, any drive where most files match the archive by digest and archive path is refused as a whole.
4. **One plan (F7).** The forecast and the run use ONE plan object (shared with `pruneOneCopy`). A copy that wasn't in the forecast is never moved.
5. **Backup proof (F8).** Decision 1(b) counts only an attestation made on the ARCHIVED record after promote, not attestations carried over from the source (`PromoteToArchiveJob+Steps.swift:613-617`).
6. **No network mounts (F6).** The lane refuses files on network mounts. Confirm on a real Mac whether the archive volume can appear as a share.
7. **Tier 2 coverage = 100% (F3).** Coverage means 100% of the candidate's content, less named black, bars or silence at the very ends. The uncovered spans are stored and shown.
8. **Tier 2 proof density (F4).** Prove over dense windows covering the whole candidate, leave blank and low-detail frames out of the evidence, require continuous audio alignment, and add the review's three false-positive fixtures (similar scenes, re-shoot, the same tape captured twice with different trims).
9. **Honest baseline (F9).** Leave archive-volume files out of the measured excess (about 4.1 GB).

C05's test sketches become the "tests first" items of Phase 1 (amendments 1–6, 9) and Phase 2 (7–8). Still to open: whether PrunePlan leaves out A/V pair members, and whether the attestations copied at promote reach the archived record or only the manifest row.

---

## Rick's decisions (2026-10-07)

1. **The archive copy may be the ONLY copy left**, provided the confirmation dialog says so plainly
   *before* "OK to delete". For example: "After this, the Master Archive copy on <volume> will be the
   only copy of these N videos. Its last fixity check: <date>, OK." The dialog lists, per item, what
   stays and what goes.
2. **Containment, in Rick's words:** "if the master archived version is 2 hours and the copies are 1
   hour, then we won't lose anything; if the master is 1 hour and the copies are 2 hours, it's a
   problem." Encoded as:
   - Tier 1 (byte-identical): same bytes, so same length by construction.
   - Tier 2 (contained): 100% of the copy's content must be found inside the archived master
     (amendment 7), AND a hard belt-and-braces guard: **a copy whose duration exceeds the archived
     master's (beyond a small container tolerance) is NEVER offered for deletion**, whatever any other
     signal says. It's shown instead as "this copy is LONGER than the archive master; the archive
     may be missing footage", a curation flag, never a delete.
3. The CLEAN UP sidebar section in Triage (excess copies · duplicates · possible repeats, with counts
   and GB) shows only with the Curator toggle on.
