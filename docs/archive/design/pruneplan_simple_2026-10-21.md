# PrunePlan, simplified — design for Rick's decision (2026-10-21)

**Rick's rule:** check for dups and copies, offer to delete; if none, say so; otherwise the person deletes what they want. If it is too hard to tell, don't prune — say "no obvious choices".

**In one sentence:** once a file is promoted, offer its byte-identical extra copies for the Trash; for everything else, say "no obvious choices" and why.

## 1. Today

About 6,260 production lines across 12 files, plus about 4,000 test lines (~150 tests). `PrunePlan.plan` has CCN 52, and the prune files carry 80 points of the CCN-15 excess baseline (50 of them in PrunePlan.swift). Complexity was measured with `scripts/complexity_metrics.py`.

| file | lines | worst CCN |
|---|---|---|
| Core/PrunePlan.swift | 1245 | plan 52, logLine 26 |
| Core/ExcessCopiesPlan.swift | 465 | 11 |
| MediaOps/PruneApplyJob.swift | 789 | run 23 |
| MediaOps/VideoScanModel+PruneApply.swift | 877 | pruneOneCopy 23 |
| MediaOps/VideoScanModel+PruneVerification.swift | 330 | 13 |
| MediaOps/PruneApplyDetailView.swift, PruneBarSettingsSection.swift | 231 | — |
| MediaOps/ExcessCopiesJob.swift, VideoScanModel+ExcessCopies.swift, Catalog/ExcessCopiesPane.swift | 1117 | — |
| Archive/ArchivedWhatNextSheet.swift | 908 | 11 |
| Archive/VideoScanModel+MediaLedger.swift | 527 | 24 |

**Concepts today:**
- Families grouped by a segmented or partial key, not the full SHA-256.
- Versions reached through up to 4 provenance hops, which go to the Trash on provenance alone, with no byte check.
- "Might be copies" (name-alikes) with Hash to confirm.
- Locked pair halves.
- The **ImportanceBar** (★/★★/★★★ thresholds, cloud/off-site attestations, 6 settings).
- Keeper election, overrides logged to the ledger.
- Note carry.
- Trusting the promotion original by its stat stamp.
- Survivor stamps.
- A 200-row cap.
- A second lane (Tidy "Delete excess copies" Tier 1) with sampled-hash nominations, a duration rule, backup-like drive detection, Angel holds, a Keep store and a ≥4★ hold.

## 2. The simple design

**Offered for the Trash only if all of these hold:**
- **R1:** its full SHA-256 equals the digest of a live `archive_copies` row whose `fixity_verified_at` is set.
- **R2:** it is a live row with no removal state.
- **R3:** it is not an archive copy, not inside the archive root, and not on the archive volume. FamilyArchive is never listed.
- **R4:** its drive is mounted, local, and not Read-only or Archive-backup (the existing `BulkDeleteGate`).
- **R5:** it is not a recovered A/V pair half.

**The person sees** one flat list grouped by archived file, every row checked, and confirms. There is no score, no bar, no keeper and no override.

**At the move** (the existing pipeline, cut down):
1. Read the archive copy's full SHA-256 once per batch; it must equal the archive digest.
2. Read the candidate's full SHA-256; it must equal the archive digest. The promotion original is no longer trusted on its stamp.
3. Re-check `JunkDeletionGuard`.
4. `trashItem` only, with a `copyTrashed` ledger line per file, one `approval` line per batch, and START/OUTCOME log lines.

**"No obvious choices"** — never pruned, and the reason is shown in words:

| case | wording |
|---|---|
| not promoted | "not in the Master Archive yet" |
| archive copy not verified | "the archive copy hasn't been verified yet" |
| version (trim, balance, transcode) | "a version, not the same bytes" |
| same name, different digest | "same name, different footage" |
| no full digest | "not hashed yet" |
| drive offline | "drive not connected" |
| network, Read-only or Archive-backup drive | "drive is protected" |
| pair half | "part of a recovered A/V pair" |
| missing on disk | "not found where the catalog says" |
| mismatch at the move | "not the same bytes as the archive copy — kept" |

**Cut entirely:**
- families, provenance hops, name-alikes and Hash to confirm;
- the ImportanceBar and its settings, keeper election, override and attestation gating;
- note carry (notes, stars and tags are keyed by digest, so an identical copy carries nothing the archive row lacks; *codex must verify this*);
- survivor stamps;
- the sampled-hash, duration, backup-like and ≥4★ rules.

**Attestations:** advice only. The confirmation says one sentence: "N files will exist only in the Master Archive after this", naming any without a cloud or off-site "yes".

**The 200-row cap stays** as a scale guard. Apply acts only on rows that were shown.

## 3. What it would offer today

Measured on the catalog at the 19:08 checkpoint, read-only.

- 142 promoted contents; all 143 archive copies are fixity-verified.
- **The simple rule offers 27 files / 536.4 GB across 22 promoted contents:**

| drive | files | GB |
|---|---|---|
| MediaExpansion | 9 | 383.0 |
| LaCieWorkspace | 8 | 66.1 |
| SanDiskWorkspace | 7 | 41.1 |
| CrucialX10 | 1 | 29.9 |
| CrucialX9 | 1 | 13.5 |
| Projects | 1 | 2.7 |

- **Today's sheet** default-checks only ~5 files / 39.0 GB of these, because of the ★★★ bar and keep-one. It also offers 1 version (45.8 GB) that would go to the Trash on provenance alone.
- **"No obvious choices":** 1 version (45.8 GB), 6 same-name/different-digest files (13.9 GB), 2 same-digest files on the FamilyArchive volume outside the archive tree, and 4,420 not hashed yet. 120 promoted contents have nothing to prune.
- **After an all-checked run, 18 of the 22 items exist only in the Master Archive.** 16 of them have a cloud or off-site "yes", 1 has only "n/a", and 1 has nothing.

## 4. Removal plan

- Delete PrunePlan.swift and the bar settings.
- Cut ExcessCopiesPlan to ~150 lines (R1–R5 plus the reasons).
- PruneApply 877 → ~350, PruneVerification 330 → ~150, WhatNext sheet 908 → ~450, ledger prune parts −250, ExcessCopies model+job −400, PruneApplyJob −100.
- **Net about −3,800 production lines and −2,500 test lines (about 30 focused tests added). The CCN-15 excess goes from 80 to about 0.**

**Kept unchanged:**
- all gates (archive volume and tree, Read-only and Archive-backup, network, viewer Mac) and the offline refusal;
- `deleteConfirmedJunk(.toTrash)`, `JunkDeletionGuard` and the ledger lines;
- the `archive_copy_never_trashed` trigger;
- PruneApplyJob pause and cancel, and the per-copy outcomes.

**Risks:**
1. Many items become archive-only by default.
2. Every archive file is re-read each batch (about 0.5 TB per side for today's backlog).
3. The claim that notes, stars and tags are keyed by digest must hold in the app model.
4. Trims are only deleted by hand (intended).
5. The Promote flow's UI changes.

**Invariants for codex:**
- **I1:** no move unless the full SHA-256 of the archive copy and of the candidate were both read in this batch and both match.
- **I2:** nothing on the archive root or volume, or on a Read-only, Archive-backup, network or offline drive, is ever listed or moved.
- **I3:** `.toTrash` only.
- **I4:** every outcome is named; no hold is reported as success.
- **I5:** a row that changed between the list and the move is held.
- **I6:** a version or a name-alike can never reach `pruneOneCopy`.
- **I7:** one ledger line per moved file, plus one approval line per batch.
- **I8:** no note, star or tag is lost.
- **I9:** no O(records) work in view bodies.

## Decision for Rick

1. Adopt R1–R5 plus "no obvious choices"? (recommended)
2. Default checks: **all identical copies checked** (leaves 18 items archive-only), or a **"Keep one working copy" toggle**, off by default?
3. Attestations: advice only (recommended), or drop them from the sheet?
