# NDSA Levels of Digital Preservation v2.0: self-assessment of the VideoScan Master Archive

Date: 2026-10-02 · Assessor: Claude (qa, read-only research) · Requested by Rick · Main at `8a88db33`

## Summary

1. **Highest level fully met: Storage 0 · Integrity 0 · Control 1 · Metadata 2 · Content 1.** The software is ahead of the storage, but the storage is where a loss would actually happen.
2. The **Storage** score is about geography. As far as the repo and notes show, every copy of archived media is in one building. NDSA's own definition says "A desktop and a hard drive in the same workspace is not considered two separate locations." Rick may know of an off-site copy that the repo doesn't. Ask him.
3. **Integrity** fails Level 1 on one cell only: nothing virus-checks content. Otherwise it's strong. SHA-256 is computed at Promote, and Verify Archive Copies re-reads every file on demand. But Verify runs only when Rick starts it, so "fixed intervals" (Level 3) is unmet.
4. The protection that is good: write-once Promote with journal recovery, the `uchg` lock, volume-wide delete refusal, and Media Ledger agent attribution. All of it lives inside the app, and none of it defends against fire, theft or a dead RAID enclosure.

| Area | L1 Know | L2 Protect | L3 Monitor | L4 Sustain | **Fully met** |
|---|---|---|---|---|---|
| Storage | partial | unmet/unknown | unmet/unknown | unmet | **0** |
| Integrity | partial (no virus check) | partial | partial (no schedule) | partial | **0** |
| Control | met | partial | partial | unmet | **1** |
| Metadata | met | met | unmet | partial | **2** |
| Content | met | partial | partial | partial | **1** |

Cheapest next steps, by value: (a) put one verified copy of the archive somewhere else (Storage 0→1; ~1 day, ~$100–200 for a drive); (b) schedule Verify Archive Copies monthly and run one ClamAV pass (Integrity 0→1, and most of 3; ~½ day); (c) emit that off-site copy as a BagIt bag built from the 00_Index manifest (~½–1 day).

Legend: **met** = evidence shows it's done · **partial** = some of it is done, or it's done in the app but not at the level the cell means · **unmet** = no evidence · **unknown — ask Rick** = the repo can't tell · **N/A** = doesn't apply. Where a cell is in doubt, it's scored down.

Scope: this scores the Master Archive (the designated archive tree on the `FamilyArchive` volume) plus the catalog and logs that describe it. It doesn't score the wider working collection on the scratch and retired drives.

---

## 1. Storage

| Lvl | Criterion (verbatim, NDSA v2.0) | Status | Evidence |
|---|---|---|---|
| 1 | "Have two complete copies in separate locations" | **partial; separate location unknown — ask Rick** | Promote is "a copy, never a move. Sources remain until a separate human decision" (`docs/guides/media-archive.md` §5). So many archived items also exist on a working volume (LaCie master, Projects). But "Have two complete copies" means the whole archive, and the prune planner may trash the extra copies once "Verified archive + another device" holds (§9). The archive tree itself exists once, on the Pegasus RAID5 (memory `reference_storage_layout_2026_08_13.md`). The guide says, "RAID redundancy is not a backup against deletion, fire, theft, controller failure, or loss of the whole enclosure" (§2). Copy 2 is the working drives, same room. No complete second copy of the archive tree is documented. |
| 1 | "Document all storage media where content is stored" | **met** | Volume roles and trust live in the catalog (`VolumeRole`, `VolumeTrust`, `retiredAt`; guide §3). The hardware layout is written down (RAID5 4×4 TB, APFS volumes, reserves, topology) in memory `reference_storage_layout_2026_08_13.md` and `project_volume_roles_rick_2026_07_23.md`. |
| 1 | "Put content into stable storage" | **met** | There is one designated Master Archive (UUID-bound; guide §3). The whole volume refuses bulk delete (`ArchiveVolumeProtection.swift`, ARCH-12, 2026-09-22). The RAID is on a pure-sine UPS (since 2026-08-15), and Media Patrol runs weekly (memory notes). |
| 2 | "Have three complete copies with at least one copy in a separate geographic location" | **unmet / unknown — ask Rick** | Notes describe the off-site copy as planned only: an off-site NAS "isn't ready", and cloud is "the eventual goal but not started in bulk" (`project_archive_strategy.md`). Rick's standing ruling is no iCloud archive via the app until the app is proven stable (`project_library_identity_design.md`). Backup attestations record the user's word about cloud and off-site copies. The app never verifies them (`BackupAttestation.swift` header). |
| 2 | "Document storage and storage media indicating the resources and dependencies they require to function" | **partial** | The dependencies are written down: the Pegasus DEXT driver approval, Thunderbolt topology, UPS, the APFS reserve gotcha and the power-strip failure mode. They're in private memory notes, though, not in a maintained document the family could use without VideoScan. `docs/research/storage_raid_recommendations.md` covers hardware choice, not running dependencies. |
| 3 | "Have at least one copy in a geographic location with a different disaster threat than the other copies" | **unmet / unknown — ask Rick** | Same as L2. |
| 3 | "Have at least one copy on a different storage media type" | **unknown — ask Rick** | The archive is on HDD RAID5, and the working copies are mostly HDD (the LaCie master is a single 7200 rpm disk). Scratch SSDs exist but are not designated copies. There's no evidence of tape, optical or cloud object storage holding the archive. |
| 3 | "Track the obsolescence of storage and media" | **partial** | `VolumeTrust` has Aging and Unreliable, and drives get retired (guide §3). Media Patrol and the `promiseutil -C event` check catch failing members. There's no record of drive age or purchase date and no replacement horizon. |
| 4 | "Have at least three copies in geographic locations, each with a different disaster threat" | **unmet** | — |
| 4 | "Maximize storage diversification to avoid single points of failure" | **unmet** | The archive depends on one RAID enclosure, one controller and one building. |
| 4 | "Have a plan and execute actions to address obsolescence of storage hardware, software, and media" | **partial** | The retire-and-migrate workflow has been carried out (several drives retired May–Aug 2026; `project_archive_strategy.md`). There's no forward plan for the RAID itself ("add another faster RAID in a year or two" is an intent, not a plan). |

**Highest fully met: 0.**

**Cheapest steps to reach Level 1, then 2:**
1. **Make copy 2 of the whole archive tree and keep it outside the building.** One external HDD, about the size of the archive tree (it's still small; Angel promotion is gated by the 10% goal). Copy with `rsync -a`, then validate against the 00_Index manifest's SHA-256 column. Rotate it to a trusted second location. Effort: ~1 day including the script, ~$100–200. This alone meets Storage L1, and with the working copies it gets close to L2's "three copies". Better still, write it as a BagIt bag (see §6).
2. **Then the cloud leg** (Backblaze B2 / S3 Glacier class, ~$1–6/TB/month), once Rick lifts the iCloud ruling or picks a non-Apple provider. It brings a different media type and a different disaster threat at once (L3). Effort: ~1–2 days to script it with manifest-based verification. Rick decides.

## 2. Integrity

| Lvl | Criterion (verbatim) | Status | Evidence |
|---|---|---|---|
| 1 | "Verify integrity information if it has been provided with the content" | **N/A** | Family camera, tape and phone sources don't come with checksums. |
| 1 | "Generate integrity information if not provided with the content" | **met** | Promote computes a full-file SHA-256 of source and destination and verifies the destination through its own descriptor (`ArchivePromoteEngine.swift`, guide §5; since 2026-08-15). The result is stored as `archiveFixity` (`ArchiveFixity.swift`) and in the manifest `sha256` column. |
| 1 | "Virus check all content; isolate content for quarantine as needed" | **unmet** | Nothing in the repo scans for malware (searched for clamav, virus, malware, XProtect: no hits in the archive or ingest code). |
| 2 | "Verify integrity information when moving or copying content" | **met** | Promote hashes before and after and re-checks source identity (ARCH-7, ARCH-13). Update… moves are a single `renameatx_np(RENAME_EXCL)` with identity checks (ARCH-1). Delete Duplicates full-compares both files before unlinking (memory `feedback_delete_safety_principle.md`). Transcodes verify with framemd5 (`TranscodeJob+FrameMD5.swift`). |
| 2 | "Use write-blockers when working with original media" | **unmet** | There's no write-blocking or read-only-mount policy for camera cards or old drives. Promote opens the source `O_RDONLY|O_NOFOLLOW`, but scanning mounts sources normally (read-write). |
| 2 | "Back up integrity information and store copy in a separate location from the content" | **partial** | The digests exist in two places: the 00_Index manifest on the archive volume (with the content), and the catalog's `archiveFixity` on the boot SSD (a different device, same room). Verify Archive Copies exists because one copy got clobbered and the other restored it (GH #167, 2026-08-20). Neither copy is off-site. |
| 3 | "Verify integrity information of content at fixed intervals" | **partial** (capability, no schedule) | `VerifyArchiveCopiesJob.swift` (2026-08-20) re-reads every archive file and compares it with the manifest. Its header says it "doubles as the periodic fixity audit". It starts only from a button in `ArchiveView.swift`. No timer, LaunchAgent or nightly hook starts it (the nightly jobs are test, coverage and adversarial-review jobs). |
| 3 | "Document integrity information verification processes and outcomes" | **met** | The process is documented in the `VerifyArchiveCopiesJob.swift` header (MATCH / MISMATCH / MISSING / ORPHAN / NOT LOCKED / DATE DISAGREES) and in `docs/practices/invariants/Archive.md` ARCH-8. Outcomes go to the MFO row, `catalog.log` and `videoscan.log`. |
| 3 | "Perform audit of integrity information on demand" | **met** | Verify Archive Copies runs on demand. Bind Fixity to Volume re-reads and re-binds legacy stamps per volume (`BindFixityToVolumeJob.swift`, 2026-09-23). |
| 4 | "Verify fixity in response to specific events or activities" | **met** | Fixity is checked at Promote, at Update… moves, at duplicate deletion, after transcodes, and when legacy stamps are re-bound. A UUID mismatch is a hard refusal (guide §3). |
| 4 | "Replace or repair corrupted content as necessary" | **unmet** | On a MISMATCH, Verify clears the fixity and flags the file, by design ("never to paper over"). There's no repair-from-another-copy path, and no second verified copy of the archive to repair from. |

**Highest fully met: 0** (the virus-check cell alone. Everything else at L1 and L2 is met or nearly met.)

**Cheapest steps:**
1. **Run one ClamAV pass over the archive tree and log the result**, then scan each new Promote batch (or monthly). `brew install clamav`, then `clamscan -r --infected` with the log kept in `~/Library/Logs/VideoScan/`. Video files are low-risk, but this cell is binary. Effort: ~2 hours. That completes L1.
2. **Schedule Verify Archive Copies** (monthly, or weekly after Media Patrol) as an MFO job on the M4's overnight window, with its OUTCOME line in the morning brief. That meets L3 "fixed intervals". Also commit to a read-only mount (`diskutil mount readOnly`) for original media, which closes the L2 write-blocker cell at zero cost. Effort: ~½ day, plus a tests-and-sensor change per the feature checklist.

## 3. Control

| Lvl | Criterion (verbatim) | Status | Evidence |
|---|---|---|---|
| 1 | "Determine the human and software agents that should be authorized to read, write, move, and delete content" | **met** | Decided and written down. ARCH-5: "Archived means read-only. Promote locks every file; only Update… unlocks → changes → relocks". ARCH-12: no bulk delete on the volume. Only Rick changes name and date (`docs/practices/invariants/Archive.md`). |
| 2 | "Document the human and software agents authorized to read, write, move, and delete content and apply these" | **partial** | Documented for VideoScan's own verbs, and applied: every archived file carries `UF_IMMUTABLE` (`uchg`) (`ArchiveFileLock`, `ArchiveLockJob.swift`, 2026-09-27), and every delete verb goes through one refusal choke point (`ArchiveVolumeProtection.swift`). Agents outside the app (Finder, Terminal, other apps, backup tools) aren't documented. `uchg` is a user flag the owner can clear, and Archive.md lists "`schg` is not used" as accepted. Whether the one-time lock catch-up has completed is **unknown — ask Rick** (Verify reports NOT LOCKED files). |
| 3 | "Maintain logs and identify the human and software agents that performed actions on content" | **partial** | The Media Ledger (`MediaLedger.swift`, `MediaLedgerEvent.swift`, 2026-09-13) is append-only JSONL with an `Actor` (e.g. rick or angel) and timestamps, and it's mirrored into `00_Index/` after each Promote batch (GH #170). The guide itself says "complete event coverage/portable mirroring not established" (§1, §9). Actions outside the app aren't logged. |
| 4 | "Perform periodic review of actions/access logs" | **unmet** | The nightly adversarial review checks code changes, not the archive's action logs. Nobody reviews the ledger on a schedule. |

**Highest fully met: 1.**

**Cheapest steps:**
1. **Write a one-page "who may touch the archive" note** inside `00_Index/`. List VideoScan Promote and Update…, Rick, any backup tool used for copy 2, and "nothing else". Add a rule for the OS side: the archive volume mounts read-write only on the M4. Confirm the lock catch-up completed. Effort: ~1 hour. That meets L2.
2. **Add a monthly ledger digest line to the morning brief**: counts by actor and kind for the last 30 days, plus any archive file whose `mtime` or lock state changed with no ledger event. That's a cheap periodic review (L4) and also finds holes in ledger coverage (L3). Effort: ~½ day as a Python script over the JSONL.

## 4. Metadata

| Lvl | Criterion (verbatim) | Status | Evidence |
|---|---|---|---|
| 1 | "Create inventory of content, also documenting current storage locations" | **met** | The catalog holds every record with its path, volume UUID and scan context (`ScanContext.swift`). The portable `00_Index/Archive_Inventory_Manifest.csv` records the archive relative path, SHA-256, size and source path/volume (guide §5). |
| 1 | "Backup inventory and store at least one copy separately from content" | **met** (weakly) | The catalog (App Support, boot SSD) is a separate copy of the inventory on a different device from the archive volume. The catalog store keeps a one-generation backup (`CatalogStore.swift`). Catalog bundles have been exported to iCloud before (memory, July 2026). Whether that export happens on a schedule is **unknown — ask Rick**. |
| 2 | "Store enough metadata to know what the content is (this might include some combination of administrative, technical, descriptive, preservation, and structural)" | **met** | Technical: ffprobe codec, container, geometry and audio fields in the catalog. Descriptive: date and confidence, people, place, rating and notes in the manifest. Preservation: SHA-256, readiness token, source lineage and backup attestations. Administrative: promotion time and copy IDs. Structural: `README_Naming_and_Layout.txt` and the bucket and decade layout (guide §4–5). |
| 3 | "Determine what metadata standards to apply" | **unmet** | The manifest CSV and ledger JSONL use a home-grown schema. No PREMIS, PBCore, Dublin Core or METS mapping has been chosen (searches found no use). |
| 3 | "Find and fill gaps in your metadata to meet those standards" | **partial** | Readiness and Angel find missing dates, unverified audio and unknown formats (guide §6–8), but not against a standard, because none has been chosen. |
| 4 | "Record preservation actions associated with content and when those actions occur" | **partial** | The promote journal (`ArchivePromoteJournal.swift`: intent, renamed, published, done) and Media Ledger events (archived with fixity, attestation, set aside or restored, copy trashed) are timestamped. Coverage isn't complete (guide §9). Verify runs log to text logs, not to per-file ledger events. |
| 4 | "Implement metadata standards chosen" | **unmet** | — |

**Highest fully met: 2.**

**Cheapest steps:**
1. **Pick PREMIS (events and agents) plus Dublin Core (descriptive) as the named standards** and write a one-page crosswalk. Manifest columns map to dc:date, dc:subject and so on. Ledger kinds map to PREMIS eventType (`archived` → ingestion, Verify MATCH → fixity check, `copyTrashed` → deletion), and ledger `Actor` maps to PREMIS agent. No schema change, only a document. That meets L3 cell 1 and frames "fill gaps". Effort: ~½ day.
2. **Have Verify Archive Copies write a ledger `fixityCheck` event per file** (an additive enum case). Fixity history then lives with the archive and moves L4 cell 1 toward met. Effort: ~½ day plus tests. This is a data-path change, so it needs the safety-critical checklist.

## 5. Content

| Lvl | Criterion (verbatim) | Status | Evidence |
|---|---|---|---|
| 1 | "Document file formats and other essential content characteristics including how and when these were identified" | **met** | ffprobe identifies codec, container, geometry, fps, scan type and audio. `ScanContext.scannedAt` records when, and the manifest readiness token carries `format=safe|at-risk:<codec>|unknown`. Caveat: the ffprobe version isn't recorded per record. |
| 2 | "Verify file formats and other essential content characteristics" | **partial** | The ffmpeg decode checks (`VerifyVideoJob.swift`, `VerifyAudioJob.swift`) show a file is decodable. That isn't the same as conforming to its format specification (the NDSA definition). No MediaConch, JHOVE or PRONOM/Siegfried identification is in use (searched). |
| 2 | "Build relationships with content creators to encourage sustainable file choices" | **N/A / unknown — ask Rick** | The creators are family members. Whether Rick asks them for originals rather than messaging-app re-encodes isn't recorded. |
| 3 | "Monitor for obsolescence, and changes in technologies on which content is dependent" | **partial** | There's a static at-risk codec table (`ArchiveReadiness.formatRisk`: DV family, MPEG-1/2, Sorenson, Indeo, RealVideo, WMV/VC-1), surfaced at Promote. Nothing reviews the table against an outside source on a schedule. Note: MPEG-2 is flagged at-risk here but is #4 on LOC's preferred list (below). |
| 4 | "Perform migrations, normalizations, emulation, and similar activities that ensure content can be accessed" | **partial** | The capability exists: Transcode makes FFV1 `-level 3 -g 1 -slicecrc 1` in MKV with framemd5 verification (`TranscodeJob+Args.swift`). Angel's optional "lossless (FFV1) copy for at-risk formats" writes `.vs.preserve.mkv`, but it's off by default (guide §6). No migration programme has been carried out over the archive. |

**Highest fully met: 1.**

**Cheapest steps:**
1. **Add format identification and conformance at Promote**: record `ffprobe -version`, plus a Siegfried (PRONOM PUID) or MediaConch policy result per file in a manifest trailing column. The manifest already supports trailing columns. Effort: ~1 day. That meets L2 cell 1.
2. **Turn on the FFV1/MKV companion for the DV and MPEG at-risk set** at Promote or as a backfill MFO job. Keep the native original as the master; the guide's representation table already says this. Verify each companion by framemd5 and record it as a ledger event. This starts real L4 activity. Effort: the code exists, so the cost is about 2× storage for that subset plus an overnight run.

## 6. BagIt (RFC 8493) and format notes

**BagIt compatibility of the Master Archive: not compatible today, close to it.** RFC 8493 requires a `bagit.txt` declaration, a `data/` payload directory and at least one `manifest-<algorithm>.txt` with `<checksum> <filepath>` lines relative to the bag root. The archive tree puts its media buckets at the root next to `00_Index/`, and its digests are in a CSV, not a BagIt manifest. Turning the live archive into a bag would mean moving every file under `data/`. That's a mass rename on the near-read-only volume, and it isn't recommended.

**Recommended: make copy 2 (and later copies) a BagIt bag.** Build the bag from the 00_Index manifest. The payload is a copy of the archive tree (00_Index included) under `data/`. `manifest-sha256.txt` comes straight from the manifest's `sha256` and relative-path columns, after one fresh hash on write. `bag-info.txt` carries Bagging-Date, Payload-Oxum and the source volume role. You can then validate with standard tools (e.g. `bagit.py --validate`) without VideoScan, which serves the guide's goal that the family can understand the archive "without VideoScan". Effort: ~½–1 day for a Python script, plus one full read-back. Watch out for paths that need encoding in BagIt (spaces are fine; CR, LF and `%` must be percent-encoded).

**Format and migration (LOC Recommended Formats Statement, "Video – file-based and physical media").** LOC lists as preferred, in order: IMF (MXF); **FFV1 "Version 3 only, as defined by RFC 9043" in "Matroska (.mkv) container"**; ProRes 4444(XQ)/4444/422 HQ in QuickTime; MPEG-2 (ISO/IEC 13818); XDCAM in MXF. MPEG-4 (.mp4) is acceptable as a viewing proxy. VideoScan's FFV1 preset (`-level 3`, all-intra, slice CRCs, MKV) matches the #2 preferred format. The archive's policy is to keep native DV with PCM as the source master and add FFV1 as an optional companion. That's the right call: re-encoding can't improve the original, and a byte-identical original keeps fixity simple. Native DV isn't on the LOC preferred list, which is the argument for making the FFV1/MKV companion standard for DV and older codecs rather than optional. Also reconcile the at-risk table with LOC on MPEG-2.

## 7. Open questions for Rick (one at a time)

1. Does any copy of the FamilyArchive archive tree, or of the LaCie master, live outside the building today? (This alone decides Storage L1.)
2. Is the catalog (App Support) backed up off the M4 on a schedule (Time Machine, bundle export, or other)?
3. Did "Lock files already in the archive (one-time)…" complete cleanly?
4. Is iCloud still off the table for the archive, or would a non-Apple provider (B2) be acceptable for the cloud leg?

## Sources

- NDSA, *Levels of Digital Preservation Matrix V2.0* (Alternative View, B/W), Levels of Preservation Revisions Working Group, October 2019. Fetched 2026-10-02 from OSF component https://osf.io/2mkwx/ (file `LevelsMatrixV2_BW_AltView.pdf`, https://osf.io/download/d582b/). All criteria above are quoted from it.
- NDSA, *Working Definitions for the Levels of Digital Preservation Version 2.0*, October 2019. https://osf.io/rynmf/ (https://osf.io/download/rynmf/). Source for "Separate locations", "Stable storage", "Verification (for preservation)" and "Write-blockers".
- NDSA Levels landing page: https://ndsa.org/publications/levels-of-digital-preservation/ (the 2019 project is at https://osf.io/qgz98/). Note: NDSA now also publishes a v2.1 matrix (https://osf.io/u8m3w/). This assessment uses v2.0 as requested.
- Library of Congress, *Recommended Formats Statement*, moving image works, "Video – file-based and physical media": https://www.loc.gov/preservation/resources/rfs/moving.html (fetched 2026-10-02).
- RFC 8493, *The BagIt File Packaging Format (V1.0)*: https://www.rfc-editor.org/rfc/rfc8493
- RFC 9043, *FFV1 Video Coding Format Versions 0, 1, and 3*: https://www.rfc-editor.org/rfc/rfc9043
- Repo: `docs/guides/media-archive.md`; `docs/practices/invariants/Archive.md`; `docs/ops/morning_brief_2026-10-02.md`; `VideoScan/VideoScan/Archive/{ArchivePromoteEngine,ArchivePromoteJournal,VerifyArchiveCopiesJob,BindFixityToVolumeJob,ArchiveLockJob,ArchiveVolumeProtection,MediaLedger,PreservationChecklist,ArchiveReadiness}.swift`; `VideoScan/VideoScanCore/Sources/VideoScanCore/{ArchiveFixity,BackupAttestation,MediaLedgerEvent,ScanContext}.swift`; `VideoScan/VideoScan/MediaOps/TranscodeJob+Args.swift`. Feature dates come from `git log --follow`: Promote/Master Archive 2026-08-15, Verify Archive Copies 2026-08-20, Media Ledger 2026-09-13, volume protection 2026-09-22, Bind Fixity 2026-09-23, archive lock 2026-09-27.
- Private memory notes (not in the repo; summarized generically): storage layout 2026-08-13, archive strategy, storage strategy, long-term plan, FamilyArchive read-only ruling, delete-safety principle, volume roles 2026-07-23.


## 8. Answers from Rick (2026-10-02)

- **Q1 off-site:** the catalog is backed up to a cloud provider; important videos are copied to the same provider piecemeal (not tracked). Planned: a 4 TB drive holding the most critical media, kept off-site with family, after junk/duplicate cleanup — target **2026-11-01**, then a full hard copy of everything. Effect: Storage reaches Level 1 for the critical set once the drive is off-site and verified against the 00_Index checksums; the piecemeal cloud copies count only for files the archive can prove are there.
- **Proportionality (Rick):** this is a family archive, not life support or NASA — improve incrementally; the off-site critical copy is the priority, beyond it is judged case by case.
- Q2–Q4: open.
