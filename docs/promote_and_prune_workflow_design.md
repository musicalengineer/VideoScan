# Promote and prune — "delete as we promote, carefully" (design, 2026-09-12)

Status: PROPOSED for Rick's ruling. Supersedes the deletion half of
`archived_duplicate_scrub_design.md` (whose scrubbable-copy rule is reused here);
the Tidy dry-run count "Copies of archived media" stays as the backlog entry.

Rick's ask, in his words: after a big promote, "This media has been archived to
RAID 5. Consider also archiving to the cloud and offsite…"; then, if the user
confirms extra copies are backed up and safe, help delete the N-1 copies,
keeping one — "we want to delete as we promote, but carefully. The app has to
take the word of the user on cloud copies and offsite copies. The user can
decide what level of backup since some media files are less important."

## The three ideas

1. **Protection level is a fact the app shows, not a guess.** For each archived
   family of copies it counts what it can verify (archive copy with fixity,
   other catalog copies, on which volumes, online/offline) and adds what the
   user has *attested* (cloud, off-site, a named drive). Shown as one line:
   `Archive ✓verified · 2 working copies (LaCie, Projects) · cloud: none · off-site: none`.
2. **The user sets the bar per importance.** Three levels, thresholds editable
   in Settings, defaults:

   | Importance (stars / disposition) | Copies required before extra copies may go |
   |---|---|
   | Important (★★★ or disposition Important) | verified archive + 1 more device + 1 off-site or cloud attestation |
   | Ordinary (★★ / unrated) | verified archive + 1 more device |
   | Low (★ / Recoverable) | verified archive alone |

   The level is never inferred from the file; it is the star/disposition
   Rick already sets, so nothing new to maintain.
3. **Deletion is a checklist with the numbers on it, and it is always
   optional.** Skipping it costs nothing: the same sheet is reachable later
   from Tidy → "Copies of archived media".

## The sheet: "Archived — what next?"

Appears once, when a Promote batch finishes with every copy fixity-verified
(never mid-batch, never on a failed file). One sheet per batch, not per file.

```
✓ 21 files (62.6 GB) are in the Master Archive on FamilyArchive (RAID 5),
  every copy read back and verified.

Protection now:  archive ✓ · 34 other copies on LaCie, Projects · cloud — · off-site —
3-2-1 tip: one more device and one copy elsewhere keeps a fire or a failed
RAID from taking everything. Nothing here deletes the archive copy.

I also have these files…
  [ ] in the cloud   (which: ____________)          ← attestation, remembered
  [ ] off-site       (where: ____________)          ← attestation, remembered
  Applies to: (•) this batch  ( ) only the ★★★ ones

What to do with the 34 extra copies (58.1 GB):
  [x] Keep one working copy  on: [LaCieWorkspace ▾]   (required for 19 ★★/★★★ files)
  [x] Move the other 15 copies to the Trash — 31.2 GB   (list…)
  [ ] Hide the kept copies from the to-do view          (already true for versions)
  [ ] Don't ask again for this importance level; use these choices

      2 files are not covered by the bar you set (★★★ with no off-site copy):
      they keep all copies until you attest one.   (list…)

                                  [Not now]   [Apply — Trash 15 files]
```

Rules the sheet enforces (all pure, all tested):
- A copy is deletable only by the scrubbable-copy rule: not in the archive
  root; its content has a fixity-verified archive copy; no human keep-mark
  (star ≥ threshold handled by the bar, Important disposition, human note);
  reachable; not a recovered A/V pair member. Offline copies are never
  elected and never counted as "extra".
- "Keep one" picks the copy on the connected working volume with the most
  free space, preferring the original over versions; the user may override.
- Files go to the **macOS Trash**, records get `purgedAt` + `ArchiveStage.trashed`
  (the Delete Confirmed Junk shape); one-tap Undo; every deletion is journaled
  with the protection line and the attestation snapshot, so the archive's
  audit trail says *why* a copy was allowed to go.
- Attestations are per record (`backupAttestations: [{kind, label, attestedAt}]`),
  additive schema, preserved on rescan and by every same-footage inheritance
  path (the userDate/userPlace rule: wherever the date goes, this goes).
  They are the user's word; the app never verifies cloud or off-site.
- The bar is checked per file, so a batch that mixes ★ and ★★★ files
  gets two different outcomes in one sheet, shown as the "not covered" line.

## Where the attestations must also live

The archive manifest. A copy of the archive on another Mac (GH #170) should
know the family said "there is a cloud copy". This is the same additive
manifest-column decision already pending for `userPlace`; proposal: add
`userPlace`, `userPlaceConfidence`, `backupAttestations` as three trailing
columns in one format bump, old readers ignore trailing columns.

## Staging

1. Attestation model + Settings thresholds + protection line (no deletion).
2. The sheet after Promote, dry-run only: shows the plan and the list, "Apply"
   disabled, so Rick can see the numbers on real batches for a few days.
3. Enable Apply (Trash + Undo + journal) behind a per-run cap (default 200
   files). Tidy → "Copies of archived media" opens the same sheet for the
   backlog (today: 100 files, 2.6 TB).
4. Later, optional: `rclone check`-style cloud verification that can upgrade
   an attestation to "verified".

## Decisions for Rick

1. The three-level bar and its defaults above.
2. Attestation scope default: whole batch, or only ★★★ files.
3. Manifest format bump: place + attestations as trailing columns (yes/no).
4. Stage 2 dry-run period before Apply is enabled: a few days, or straight to stage 3.
