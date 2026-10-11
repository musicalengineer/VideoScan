# The 959 "marked deleted, still on disk" files: machine classification, 2026-10-11

Diagnose-only. No catalog writes, no file moves, no source edits. Inputs, all read-only:
`catalog.json` (saved 2026-10-11 00:05Z, 13,796 records, copied to scratch first), every
`catalog.*.json` snapshot in App Support, `ledger/media-ledger.jsonl`, `deletions/*.csv`,
`delete-duplicates/done/`, and `~/Library/Logs/VideoScan/{catalog,videoscan,relocate}.log`.
Follows on from `diagnose_trash_and_volume_floor_2026_10_10.md` §1a.

Per-file results (they contain family paths, so they stay out of git):
`~/Library/Application Support/VideoScan/diagnostics/manually_deleted_959_2026_10_11.csv` (+ `.json`).
Each row has the bucket, a one-line reason, the full SHA-256, the survivor path and disk, related
footage, the provenance, and the analyzer junk score.

## Method

1. **Population.** This is the footer caption's own predicate (`CatalogStorageTotals.swift:401-433`):
   active records (not purged, set aside or superseded) with `archiveStage == .manuallyDeleted` and
   `sizeBytes > 0`. That gives 968 records. **959 files exist (976.0 GB)**, the same as the caption. The
   other 9 are missing at their path (7 LaCie, 1 Projects, 1 home folder) and are not in the caption.
   Every scan-target volume was online, so **offline-unknown = 0**. All 959 re-stat to their
   catalog size, so **size-changed = 0**.
2. **Byte proof.** Candidates came from the catalog's `contentHash` (`v1:` = head/mid/tail SHA-256,
   `FileHasher.swift:103-201`) or else `(partialMD5, size)`. A candidate had to be live: not purged, not
   Trashed or Deleted, not `.manuallyDeleted`, file present now at the same size. I then read **both
   files in full** (SHA-256, `F_NOCACHE`, one reader on the LaCie HDD, three on the SanDisk SSD, two on
   the SAS RAID). That was 1,494 files and 1.55 TB in 60 min, with 0 read errors and 0 files changing
   during the read. **Only full-SHA-256 matches count as proof.** The segmented hash was wrong in
   10 of 836 twin pairs (714 records, 1.2%) — see "Bugs found".
   Physical disks: LaCieWorkspace and MediaExpansion share one 8 TB USB HDD (disk24). FamilyArchive
   and Projects share the 12 TB SAS RAID (disk22). A survivor on the same physical disk is reported
   separately.
3. **Same streams, different wrapper.** Candidates were live files with the same video codec, the same
   audio codec and the same duration within 0.1 s (91 pairs, 201 files, 64 GB). Command:
   `ffmpeg -i F -map 0:v? -map 0:a? -c copy [-bsf:v h264|hevc_mp4toannexb] -f streamhash -hash sha256 -`,
   compared per stream type and ignoring stream index.
   **Positive control:** an MTS rewrapped to Matroska through a pipe kept the identical **audio**
   hash. The **H.264 video** hash changed, because TS access-unit delimiters and repeated SPS/PPS are
   not reproduced by `mp4toannexb`. So audio is the reliable rewrap detector. **Result: 0 of 219
   comparisons matched on any stream, audio included.** No rewrap of these files exists among the
   candidates.
4. **Junk.** `MediaAnalyzer.score` (`Media/MediaAnalyzer.swift`) was ported line-for-line and re-run.
   The catalog's stored dispositions were also checked: 0 are Suspected or Confirmed Junk. **Junk = 0.**
5. **Unique split** (Rick, 2026-10-11). LOW VALUE reuses the Angel predicates (`appCache` folders and
   stems, `proxyStream` < 100 kbps, `derivativeBaseStem`, the 2-minute `tooShort` floor) and
   MediaAnalyzer's render, truncated and failed-probe signals. A derivative counts as LOW VALUE only
   when the Master Archive holds a file of the same length (±0.5 s).
   **One deliberate deviation, open to veto:** AVCHD/DV camera shots under 2 min are kept when their
   event folder totals 2 min or more. The camcorder splits one event into many short shots, and
   dropping the short ones loses footage. Applied literally, the floor would move 175 files (19.0 GB)
   from KEEP to LOW VALUE.

## Buckets

| Bucket | Files | GB | Notes |
|---|---:|---:|---|
| Proven copy, survivor in the **Master Archive** | 13 | 92.5 | full SHA-256 = a file under `Breen_Family_Archive/30_Video` |
| Proven copy, survivor **elsewhere** (different physical disk) | 675 | 592.5 | 564 are SanDisk→LaCie twins (554.8 GB). 640 have one verified other disk, 35 have two |
| Proven copy, survivor on the **same physical disk only** | 1 | 0.5 | LaCie file whose only twin is on MediaExpansion (the same HDD) |
| **Cycle**: the only identical copy is also in the 959 | 27 | 150.0 | 10 distinct contents, 65.2 GB at one copy each |
| Junk (app rules) | 0 | 0 | |
| Same streams, different wrapper | 0 | 0 | see the control in Method 3 |
| Unique: **KEEP** (recommend Promote) | 228 | 123.1 | 213 AVCHD camcorder shots (56.5 GB, 5.2 h) + 15 others |
| Unique: **LOW VALUE** | 15 | 17.5 | 6 archived-footage derivatives (16.8 GB) + 9 short clips (0.7 GB) |
| Missing / size-changed | 0 | 0 | (9 more records outside the 959 are missing at their path) |
| Offline, unknown | 0 | 0 | |
| **Total** | **959** | **976.0** | |

Survivor safety: no survivor is set aside, superseded or `.manuallyDeleted`. 66 survivors are on
the FamilyArchive volume, 13 of them inside the archive root. Elsewhere-survivors by drive: LaCie HDD
565, SAS RAID (Projects or FamilyArchive outside the root) 70, M4 internal (`~/`) 34, CrucialX9 5,
SanDisk 1.

### Cycles (keep at least one of each)

All are on LaCie except one FamilyArchive file.

- **BrocktonChristmas2010.mov**, 41.5 GB DNxHD, 25 min. One copy is in a FamilyArchive FCP library
  (outside the archive root), the other in LaCie `CheesegraterArchive/ExternalRAID`. **Both** are
  hidden as deleted.
- **DV tapes under `iMovie Projects` / `highsierra_rickb`**: `Clip 03.dv` (13 GB, 60 min, ×3),
  `Clip 01.dv` (5.9 GB, 27 min, 1997, ×3), `Clip 05.dv` (4.1 GB, 19 min, ×2), `Clip 01 01.dv`, and
  `Clip 04.dv`. Clip 03 has the same length as the archived CapeCod June 1998 tape but different bytes.
- Small items: `babies tim and matt.mov` (3 MB reference movie, ×5), `large.m4v`, `Still Images`,
  a 0-stream `_compressed.mov`.

## Provenance: how they got here

**Nobody asked to delete these files, and no delete ever touched them.** None of the 959 has a
`copyTrashed` or `copyDeleted` ledger event, a row in any deletion receipt or Delete-Duplicates
`done/` record, or a trash/delete/fail line in catalog.log, videoscan.log or relocate.log. The label
was always catalog-only.

| Cause | Files | GB | When | Mechanism |
|---|---:|---:|---|---|
| Migrate/Reconcile bucket E ("safely redundant"), **carried** to a new path | 573 + 2 | 573.8 + 11.7 | set 2026-05-31 / 06-01, carried 08-17 | The retired-drive Migrates (Mini2TB, Maxtor, Seagate, InternalRaid lineage) labelled the record. The 08-17 Migrate `LaCieWorkspace/CheesegraterArchive/InternalRaid → SanDiskWorkspace/FromCheesegrater` then **copied** those already-labelled records and re-pointed them at the SanDisk copy, with the label still attached. The LaCie originals got fresh, unlabelled records on rescan. That is why the SanDisk copy is "deleted" and its LaCie twin is not |
| Migrate/Reconcile bucket E, set at this path | 377 + 1 | 306.9 + 0.0 | 2026-08-17 / 08-18 | Migrates `LaCie/{highsierra_rickb, InternalRaid, from-Mini2TB, from_mybook, ExternalRAID} → SanDisk` and `MediaExpansion → Projects` with **`skipDupsOnOtherVolumes=true`**. A LaCie file with a catalog twin elsewhere was **not copied**. It was labelled `.manuallyDeleted` (catalog-only, `VideoScanModel+Relocate.swift:400-413`), and the file was never touched |
| **Delete Duplicates / Prune stage inheritance** | 6 | 83.6 | 09-11 → 10-02 | `applyHumanMetadataInheritance` (`VideoScanModel+RepairLifecycle.swift:184-187`) copies `archiveStage` from the removed extra onto the keeper when the keeper's is `.none`. When the extra being trashed was already `.manuallyDeleted`, **the keeper inherited "deleted"**. Verified for all 6 against snapshots: the extra was MD, and the keeper flipped in the first snapshot after the removal date. Two of the keepers are on FamilyArchive (BrocktonChristmas2010.mov, Donna-MyGirl-1984-Final.mov) |

The reconcile witnesses were pre-2026-10-06. All three witness guards landed on **2026-10-06**:
`isLiveRelocateWitness` (no MD witness), `witnessIsOnDisk` (33390e95d), and
`witnessIsOffTheSourceDrive` (bf45b42d5). Before that:

- Witnesses were matched by `(size, partialMD5)` in the catalog only. They were not required to exist
  and could be MD themselves. Of the 953 reconcile-labelled files, **759 have no witness on disk
  today**. Witnesses named: InternalRaid 509 and MyBook3Terabytes 25 (both retired/offline),
  CrucialX9 295, LaCieWorkspace 146, MediaExpansion 56 (the same HDD as LaCie).
- **Mutual witnesses happened.** `relocate.log:43437` (08-17 15:49) labels the `highsierra` copy of
  `Thanksgiving2009.mo4B1F3271.mxf` with the `ExternalRAID` copy as witness. `:51791` (23:04) labels
  the `ExternalRAID` copy with the `highsierra` copy, which was already MD, as witness. A 10-09
  duplicate cleanup then removed the `highsierra` copy ("identical bytes"). The surviving copy is
  still labelled deleted (it is in LOW VALUE: a 90-min audio-only Avid track whose finished sequence
  is archived).
- 82 records list a witness on their own volume.

Why Rick remembers "asking to delete": the Migrate sheet shows these as "Manually deleted — marked,
kept for audit" (`RelocateSheet.swift:383`), and the footer says "marked deleted, still on disk".
Both read like a pending Trash. They never were one.

## What is in KEEP, in plain words

- **2009–2010 AVCHD camcorder originals** (213 shots, 56.5 GB, 5.2 h, 1080i H.264/AC-3) in
  `LaCie/CheesegraterArchive/InternalRaid/AVCHD_MTS_Files`: Thanksgiving Nov 2009 (51 shots,
  90 min), Christmas Dec 2009 (49, 119 min), the "MTS 15–102" 2010 run (77, 41 min), Hudson
  Christmas, Westford, Jan 2010 (14, 26 min), and 5 March 2010 (13, 21 min), plus 9 loose shots.
  **For almost all of this, it is the only copy.** The CrucialX9 holds 10 remnant shots, 9 of them
  catalog-"Trashed" but still on disk. Searching the archive by length and capture day turned up the
  edited Thanksgiving 2009 sequence and one Westford walk, but none of the raw shots. These are camera originals, and the catalog view and the
  Archive Angel (`fileGone` floor) both hide them today.
- **Christmas 2004 iMovie** (45 min, 14.3 GB, Animation codec; Donna).
- **Christmas 1997 clip 1 and clip 2**: two different 60-min DV tapes (13.7 GB each; different
  stream hashes; Donna).
- **Christmas 1990 part 1** (35 min DV, 7.7 GB). Part 3 is archived (proven above), and the archive
  also holds a 2-hour `Christmas_1990_2_hours.dv` that may contain part 1. Worth a look before
  Promote.
- **Uncle Terry movie** (4.5 min MJPEG, 7.6 GB, Dec 2009; Donna).
- **CapeCod 2000-something** (19.5 min ProRes, 6.3 GB; Donna). Not byte- or stream-equal to anything
  archived.
- **MyGirl (fcp1)** (2.2 min DV, 2001) and **MyGirlDonna-1984** (2.1 min DV, inside an iPhoto
  library). Versions of the archived Donna "My Girl" piece, but not provably the same file.
- **germanproject.mov** (4 min, 2010), and 5 short DV clips from **Matt's Movie** (2006; 31 sibling
  clips are proven copies).
- **Hand-check item:** `Thanksgiving-Raw_Default_denoise_thm2_nyx3_hyp1.mov` (94 min, 320x240 ProRes).
  It is a processed derivative: the archive holds its original `Thanksgiving-Raw_Default.mov` and two
  `-vs-edit` versions of this very file. It stayed in KEEP only because `_hyp1` is not an Angel
  derivative token. **I would treat it as LOW VALUE.**

## What is in LOW VALUE (nothing moves without Rick's yes)

- Derivatives whose footage is archived (6, 16.8 GB):
  - three `*.vs.archive.mov` HEVC encodes of the 1997 Cape Cod tape (the DV master
    `Family_CapeCod_1997.dv` is archived)
  - `Timmy 10th Bday Restored.mp4` and `TimmyBday-exported.mov` (the archive holds
    `Timmy_Tenth_Birthday.mp4` at the same length; a different encode at near-identical size)
  - the 90-min `Thanksgiving2009` Avid audio MXF (the finished sequence is archived)
- Under 2 minutes (9, 0.7 GB): a 101-s Christmas NH photo slideshow, `LeavingOnAPlane.m4v`
  (99 s), two iPhoto phone clips (20 s and 7 s), `Donna-DV-NTSC-Color-short.mov` (116 s), and
  family moments at 24–40 s (Dicky & Donna astronomy 1995, Halloween Matt, Dan 2001), plus a 12-s
  `Libby-7-sample2`. **The family moments are short but real. Recommend a 2-minute eyeball, not a
  bulk Trash.**

## Recommended action per bucket

Rules respected: Trash only, prove the surviving copy at delete time, archived = read-only, no bulk
delete on FamilyArchive.

| Bucket | Recommendation |
|---|---|
| Proven copy, survivor in the archive (13, 92.5 GB) | Safe in principle. **Do not script a Trash.** Clear the stale label (below) so the existing byte-verified Excess Copies / "Archived — what next" path picks them up and re-proves the archive copy at delete time |
| Proven copy, survivor elsewhere (675, 592.5 GB) | For 640 of them, deleting leaves **one** copy, on a workspace drive and not in the archive. 445 GB is SanDisk `FromCheesegrater/Avid MediaFiles` MXF (258 video-only and 237 audio-only halves), whose twins are on LaCie. **Rick's call:** (a) keep both until the footage is Combined and Promoted (safest; this is the A/V-stitching backlog), or (b) Trash the SanDisk side via Delete Duplicates with LaCie as keeper (dup-keeper precedence HDD > SSD), accepting a single copy. Today's "only two copies — not pre-selected" rule will hold them unless he opts in |
| Proven copy, same physical disk only (1) | Keep. A same-disk twin is not a survivor |
| Cycle (27 files, 10 contents, 150 GB) | Keep at least one of each. Promote the DV tapes and BrocktonChristmas2010.mov first, then the extra copies become ordinary Tier-1 removals. **Never Trash both** |
| Junk / same-streams | None found |
| Unique KEEP (228) | **Promote**. Effectively about 20 decisions: 5 AVCHD event folders + 15 single files. Needs the label cleared first, because the Angel and Promote paths exclude `.manuallyDeleted` |
| Unique LOW VALUE (15, 17.5 GB) | Rick eyeballs the list (2 minutes), then Trash via the app. Hand-move the Thanksgiving-Raw denoise file here if he agrees |

**Prerequisite for every row above (needs Rick's sign-off, catalog metadata only):** clear the false
`.manuallyDeleted` label from all 959. Not one of them was a real removal, and the label hides
footage that is the only copy. This is the F2/F5 territory from the 10-10 report, and it should go
through `/safety-critical`, because re-admitting rows puts them back in the delete pools.

## Bugs found (separate dispatches, one each)

- **B5 (data-risk, `/safety-critical`):** `VideoScanModel+RepairLifecycle.swift:184-187`. Stage
  inheritance in Delete Duplicates and Prune can label the **keeper** "deleted" when the extra was
  `.manuallyDeleted`. It hid the last copy of 6 files, 2 of them on FamilyArchive. `archiveStage`
  (and arguably `lifecycleStage` `.trashed` / `.deletedPermanently`) must never be inherited from a
  removed copy. Regression test: delete an MD extra and assert the keeper's `archiveStage` is
  unchanged.
- **B6 (data-risk):** Migrate copies records already labelled `.manuallyDeleted` and carries the
  label onto the destination copy (573 SanDisk files). Needs a check that this still happens after
  the 10-06 fixes. Either skip MD records, or clear the label on a verified copy.
- The 10-06 witness fixes (33390e95d, bf45b42d5) stop **new** bad bucket-E labels. They do not
  revisit the 953 labels written before them.
- **Data point for the hash policy (important):** across 836 `v1:` twin pairs (714 records), a full
  SHA-256 found **10 pairs where the files differ despite an equal `v1:` hash and equal size**:
  - three HEVC `.vs.archive.mov` encodes of the 1997 Cape Cod tape, 3,854,349,488 B each (6 pairs)
  - four small DV clips against LaCie `InternalRaid` twins (4 pairs)

  The segmented hash reads head, middle and tail (`FileHasher.swift:16-44` already calls it
  "candidates, nothing more"). Any engine that treats `v1:` equality as identity at delete time would
  have been wrong here. Worth a grep: `ExcessCopiesPlan.swift:387` and
  `VideoScanModel+ExcessCopies.swift:151` key on `v1:`. Confirm that both full-verify before
  `trashItem`.
