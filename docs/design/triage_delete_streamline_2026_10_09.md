# Triage delete, streamlined: junk and duplicates (design, 2026-10-09)

**One sentence (Rick):** "In Triage, show me the junk and the duplicate copies I can safely
get rid of, per volume, keep one, and move the rest to the Trash in one step, and show me
it happened, right where I am."

Status: design. Rick approved the direction and the Duplicates mockup (2026-10-09); expect
iterations. Build after the Bonnie demo under `/safety-critical`; the three 🔴 fixes (§5) first.

## 1. What's wrong today (verified against main @ b273af967)
- 8 delete paths on 2 engines (`deleteConfirmedJunk`; `DeleteDuplicatesJob`), 4 different
  words ("Delete File", "Delete Junk", "Move to Trash", "Check and Remove Proven Copies"),
  confirmations from 0 (⌘⌫, row menu) to 2 sheets (Triage), defaults Trash / Cancel /
  Delete Permanently depending on the path.
- Triage's orange **Junk** button marks *Suspected*; **Delete Junk** acts on *Confirmed* only
  (TriageView.swift ~674 vs ~885). Rick marks a pile and nothing is deletable.
- The Delete Junk count leaves out archived-stage junk; `JunkDeleteAction.makeOnAct`
  re-queries ALL confirmed junk (JunkDeleteAction.swift ~90). Count ≠ deleted set.
- Row-menu "Delete Permanently…" alert: Return = Delete Permanently.
- `DeleteDuplicatesJob` unlinks (no Trash) when ≥ 3 verified copies remain.
- Refusals (archive drive, read-only drive, A/V half, offline) show in the console, a hover
  tooltip, or nowhere. Success on ⌘⌫ / row menu is silent. No junk count in Catalog; the
  Excess pane needs a manual Refresh; results need a tab switch.
- Triage's dup view leads with Steward events; per-volume "what would go, what stays" isn't
  visible (Rick: "where are the dups that are clearly candidates for deletion?").

## 2. Rulings this design rests on
1. **Trash only.** The app never deletes permanently; Rick empties the Trash daily ("trash
   day") — that is the permanent step. Removes: row-menu "Delete Permanently…", the Triage
   sheet's Delete Permanently, and `DeleteDuplicatesJob`'s ≥ 3-copies unlink tier.
2. **Marking is deciding.** A human "Junk" = Confirmed. Machine guesses stay Suspected until
   a human agrees (one click).
3. **One verb: Move to Trash**, one engine door per kind (junk: `deleteConfirmedJunk`;
   copies: the verified-copy job), one confirmation shape, one result banner.
4. **Keeper precedence** (existing ruling): Master Archive › RAID › HDD › SSD; never elect an
   offline drive; the archive and archive-backup drives are never a target; a copy LONGER
   than the archive master is never offered (Tier 1 rule).
5. Catalog knows all media (ingest ruling): nothing here hides files from the catalog; it
   only moves files the user chose to the Trash.

## 3. Triage ▸ Duplicates (the main new view)
```
DUPLICATES                     412 groups · 1.8 TB reclaimable     [Sort: GB ▾]
▾ Brockton_Xmas_1994.mov     4 copies · 41 GB each · save 123 GB
     KEEPS  FamilyArchive   …/1994/Brockton_Xmas_1994.mov    archived ✓   (why: archive copy)
     ☑      LaCie_8TB       /Imports/old/…
     ☑      SanDisk_2TB     /Shorts/…
     ☐      RAID_A          /Projects/FCP/…                  (unchecked = stays)
     Trash extras on: [LaCie_8TB ✓] [SanDisk_2TB ✓] [RAID_A]  → [Move 2 to Trash · 82 GB]
☑ 40 groups selected                       [Keep 1 each, trash extras · 610 GB]
```
- **Group = proven identical content**, from the same evidence the duplicate engine already
  trusts (whole-file digest, or the engine's verified tiers). Sampled-hash-only matches are
  shown as "Likely — verify first", never pre-checked.
- **Keeper**: chosen by §2.4, reason shown; user can click another copy to keep it. A group
  whose only eligible keeper is offline shows "Connect <volume> to clean this up" and offers
  nothing.
- **Volume chips** = Rick's old "delete dups → volume": toggle which volumes lose extras;
  "all volumes" keeps exactly one. Checkboxes override per copy.
- **Bulk**: multi-select groups → "Keep 1 each, trash extras".
- **Events panel** collapses while Duplicates is the filter (main area is the groups).
- Sorted by reclaimable GB; the header total is live.
- Built off-main from a value (no O(records) in a view body); 100k-record scale test.

## 4. Junk in Triage and Catalog
- Junk button → Confirmed. Machine suspects shown as a separate filter "Suspected (N)" with
  "Agree" (→ Confirmed) / "Not junk".
- Live **Junk chip** in Catalog and Triage toolbars: "Junk: 340 · 92 GB" → click filters to
  them.
- Delete from where you are: selection → ⌘⌫ or "Move to Trash" (same behaviour in both
  places, both write the ignore list consistently).

## 5. One confirmation, one result (all delete paths)
- Confirmation (skipped for < 10 files and < 1 GB): "Move 212 files (48 GB) to Trash?" +
  "3 held back: on the archive drive (2), A/V half (1)" with reasons; default = Move to Trash;
  Cancel = Esc.
- Result banner in place: "Moved 212 (48 GB) to Trash · 3 held back (why) · Undo".
  Undo = put back from the Trash where macOS allows (`trashItem` resulting URL), else
  "Open Trash". Rows leave the view immediately; counts refresh without a tab switch.
- Every `refused` / skipped item is listed with its reason (never console-only).

**🔴 fixes first (small, before the redesign):**
1. Triage Junk button → Confirmed (or Delete Junk includes what the user marked).
2. Delete Junk acts on exactly the set the sheet counted (pass the counted IDs; re-check
   each at the move; pin with a test).
3. Remove "Delete Permanently…" (or at minimum make Cancel the default) — superseded by ruling 1.

## 6. Invariants (for codex to attack)
1. Nothing moves unless, at move time, a keeper of that content is proven present (online,
   read in full or fixity-proven, digest-matched) and is not the target (path aliasing:
   symlink, hard link, case, firmlink).
2. Moved ⊆ what the confirmation showed; a changed plan holds, never widens.
3. Never a target: Master Archive tree/volume, archive-backup drives, read-only drives,
   network mounts, viewer-mode Mac, a copy longer than the archive master, sampled-only match.
4. Trash only: no code path in these flows calls `removeItem`/unlink; a Trash failure holds.
5. Every held item reaches the UI with a reason.
6. The count shown == the set acted on.

## 7. Reuse vs new
Reuse: `DeleteDuplicatesPlan` + forecast + `DeleteDuplicatesJob` (verified-copy engine),
Excess Tier 1 survivor checks (F1 fix), `deleteConfirmedJunk`, keeper precedence.
New: the Duplicates group view model (value, off-main), volume chips, one confirmation
component, the result banner, the junk chip. Retire: dead CatalogToolbar junk sheets, the
permanent tier and permanent menu items.

## 8. Open questions
- Undo: is put-back from the Trash reliable on every drive type, or is "Open Trash" enough?
- Should Excess copies (archived) become simply the "archive copy is the keeper" case of
  the Duplicates view, retiring the separate pane?
