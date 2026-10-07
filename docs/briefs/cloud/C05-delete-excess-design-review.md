# C05: Adversarial review of the "Delete excess copies" design

Inherits `docs/briefs/cloud/README.md`. Report: `docs/reviews/cloud/C05-delete-excess-design-review.md`.

**Kind:** design review (data-risk). Rick's primary goal: once an item's archive set (FFV1 master + access + editable) is in the Master Archive, bulk-delete every other copy of that footage. Measured: 8.99 TB catalog, 1.89 TB linked to archived items.

## Scope
- `docs/design/delete_excess_copies_2026_10_06.md` (the design).
- To check its claims: `MediaOps/VideoScanModel+PruneApply.swift`, `MediaOps/PruneApplyJob.swift`, `MediaOps/PrunePlan.swift` (or wherever `PrunePlan` lives), `MediaOps/DeleteDuplicatesFlow.swift`, `Archive/CopyFamilyAssessor.swift`, `Archive/VideoScanModel+BackupAttestations.swift`, `Archive/MasterArchive.swift` (manifest).

## Attack
1. Each tier's proof: can Tier 1 ("hash-identical to an archived file") ever delete the ONLY good copy? Think: hash collisions of sampled hashes, a stale hash on a re-written file, an archive file whose fixity failed, a manifest row whose catalog id is stale (29 such rows were found), a copy that IS the archive file reached by another path.
2. The keep rules: is every kind of copy that must survive named (the archive set, the archive's attested backups, read-only drives, Angel holds, Rick's holds)? Does the design re-prove the surviving archive copy (present + fixity) AT delete time?
3. Is building on PruneApply the right engine? What does PruneApply NOT check that the new lane needs (the Angel holds gap is known)?
4. Tier 2 "contained": what proof would actually be trustworthy for "this excerpt is inside the archived master"? What false positives would frame fingerprints give (similar scenes, re-shoots, the same tape captured twice with different trims)?
5. Bulk UX: what could make one big "Delete N copies" click go wrong? (a forecast that differs from the run, drives changing between forecast and run, offline drives.)
Classify each finding with the README format. Design flaws count as REAL with a concrete failure scenario.
