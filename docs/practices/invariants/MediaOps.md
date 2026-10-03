---
tier: data-risk
paths:
  - VideoScan/VideoScan/MediaOps/DeleteDuplicates*.swift
  - VideoScan/VideoScan/MediaOps/DuplicateKeeperPolicy.swift
  - VideoScan/VideoScan/MediaOps/SignatureVerification.swift
  - VideoScan/VideoScan/MediaOps/SignatureConcurrencyPlan.swift
  - VideoScan/VideoScan/MediaOps/JunkDeleteAction.swift
  - VideoScan/VideoScan/MediaOps/VideoScanModel+JunkDelete.swift
  - VideoScan/VideoScan/MediaOps/VideoScanModel+TrashSelection.swift
  - VideoScan/VideoScan/MediaOps/VideoScanModel+SoftDelete.swift
  - VideoScan/VideoScan/MediaOps/VideoScanModel+Prune*.swift
  - VideoScan/VideoScan/MediaOps/PruneApplyJob.swift
  - VideoScan/VideoScan/MediaOps/*Purge.swift
  - VideoScan/VideoScan/MediaOps/VideoScanModel+*Purge.swift
  - VideoScan/VideoScan/MediaOps/Relocate*.swift
  - VideoScan/VideoScan/MediaOps/VideoScanModel+Relocate*.swift
  - VideoScan/VideoScan/MediaOps/VideoScanModel+RepairLifecycle.swift
  - VideoScan/VideoScan/MediaOps/RescueFileCopier.swift
  - VideoScan/VideoScan/MediaOps/PartialFileNaming.swift
  - VideoScan/VideoScan/MediaOps/DerivedFileNaming.swift
  - VideoScan/VideoScan/MediaOps/DerivativeOutputPublish.swift
  - VideoScan/VideoScan/MediaOps/CombineOutputPublish.swift
  - VideoScan/VideoScan/MediaOps/CombineEngine.swift
  - VideoScan/VideoScan/MediaOps/CombineVerifier.swift
  - VideoScan/VideoScan/MediaOps/VideoScanModel+Combine*.swift
  - VideoScan/VideoScan/MediaOps/TranscodeJob*.swift
  - VideoScan/VideoScan/MediaOps/TrimJob.swift
  - VideoScan/VideoScan/MediaOps/TrimEngine.swift
  - VideoScan/VideoScan/MediaOps/ReformatJob.swift
  - VideoScan/VideoScan/MediaOps/RebuildAudioJob.swift
  - VideoScan/VideoScan/MediaOps/BalanceAudioJob.swift
  - VideoScan/VideoScan/MediaOps/CleanupJob.swift
  - VideoScan/VideoScan/MediaOps/CleanupFFmpegEngine.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/PrunePlan.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/CleanupEngine.swift
---
# Media File Operations: delete, prune, purge, relocate, rescue, and every job that writes media

## Invariants
1. **MOPS-1** Delete safety: a file is trashed or deleted only after proving, at delete time, that a surviving copy exists (sibling proof / signature re-read now, not a cached verdict). When in doubt, refuse. Trash over permanent unlink.
2. **MOPS-2** AT THE FINAL VERDICT IMMEDIATELY BEFORE A REMOVAL, NOTHING COMES FROM A CACHE: which physical device each counted copy is on (`DuplicateDrives.liveIdentityFresh` through `DeletionTierFacts.recheck`), the Archive Angel's holds (`inFlightRecordIDsFresh` — every plan file read — plus the model's live sets) and the Read-only marks (the marks as they are now, turned into a protection there and then) are each read fresh at that point. Caches (`liveIdentityCached`, `inFlightRecordIDsCached`, the model's snapshots) serve only forecasts, the Storage / steward displays and the per-turn pre-checks, which are advisory — the final verdict is the authority. Duplicate delete leaves the policy's number of verified copies — and an OUTRIGHT delete additionally requires those copies on at least two different drives, or the verified archive copy among them (`DeletionTierDecision.minimumDrivesForPermanent`, 2026-10-03); otherwise the copy goes to the Trash. A "drive" is a PHYSICAL DEVICE, one key per device (`DuplicateDrives`: the DiskArbitration device path of the volume the copy was stat'ed on — never the path's spelling, never the volume). Two volumes of one device — two APFS volumes in one container, two partitions of one disk, two volumes of one RAID — are ONE drive. WHAT COUNTS as a drive: a physical device holding a local volume, and a network volume (one drive per server + share). WHAT NEVER DOES: a mounted disk image (.dmg, .sparsebundle, a RAM disk — its backing file may sit on the very drive the other copies are on) and a volume whose physical device cannot be established; a copy there still counts as a copy. A copy the run LEAVES ALONE on the drive it is cleaning (in use by the Archive Angel, on a folder marked Read only) is never counted as a surviving copy for another copy of that run (`duplicateSurvivorStandingRule`). Known limit — only what cannot be seen: a hardware RAID presents as ONE device and counts as one drive (its internal redundancy is NOT a second drive); two disks in one enclosure that present as two separate devices count as two; two network shares backed by one server disk count as two (the share is all that can be seen); a volume spread over SEVERAL physical stores (Fusion Drive, CoreStorage, a multi-store APFS container) is keyed by the ONE store DiskArbitration reports — no reliable signal for "more than one store" was found in its description, so two such volumes sharing a store other than the reported one could count as two. A keeper is never elected on a retired, offline or scratch volume; no group ever loses every member, whatever the order or concurrency of the job.
3. **MOPS-3** No MediaOps lane (delete, prune, purge, relocate, cleanup) deletes, moves or trashes anything on the FamilyArchive volume or inside the Master Archive tree.
4. **MOPS-4** Outputs never clobber: a derivative, combine, transcode, trim, reformat, rebuild or rescue output is written under a partial name and published with an exclusive create/rename. Only the job's own partial file may be removed or trashed.
5. **MOPS-5** Source media is never modified by a job that produces an output. Combine (A/V stitch) muxes with `-c copy` only; no re-encode; the output is verified (streams, duration) before it is announced.
6. **MOPS-6** Relocate is copy → verify (size + digest) → only then remove the source. A failed or interrupted verify leaves the source untouched, and the catalog record follows only a verified copy; reconcile never points a record at an unverified file.
7. **MOPS-7** Catalog and disk agree after every item: a record is marked deleted, trashed or moved only after the filesystem call succeeded. Stop and Pause leave a resumable state, never a half-applied item.
8. **MOPS-8** A path used for a destructive call comes from the catalog record and stays inside its volume root; symlinks are not followed onto another volume; a renamed or replaced file (identity changed since planning) is refused.
9. **MOPS-9** Every destructive lane logs START, a result line per item and OUTCOME through the one sink (console, catalog.log, videoscan.log) and shows as an MFO row; nothing destructive runs silently.

## Known and accepted (do not report)
- A crash can leave a partial-named output behind; partial-file naming and cleanup find it later.
- Duplicate groups that elect a retired drive's copy as Keep strand data offline — a known blocker tracked separately (2026-08-14), not a new finding.
- ffmpeg/ffprobe run through the app's process runner; their presence is checked at launch.
