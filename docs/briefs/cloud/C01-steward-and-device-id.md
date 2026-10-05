# C01 — Adversarial: the content steward's way to deletion + the DeviceID sweep

Inherits `docs/briefs/cloud/README.md`. Report: `docs/reviews/cloud/C01-steward-and-device-id.md`.

**Kind:** adversarial review of merged SHAs (week of 2026-09-28). The
Delete Duplicates planner itself had five codex rounds (#258); it is NOT in scope,
except as the door the steward calls.

## Scope
- `VideoScan/VideoScan/Steward/*.swift` (9 files, ~3.9k lines; trial UI, 2026-10-03/04).
- The front door it must use: `VideoScan/VideoScan/MediaOps/DeleteDuplicatesFlow.swift`.
- `9783f286`: `VideoScan/VideoScanCore/Sources/VideoScanCore/DeviceID.swift` and the
  six call sites in that commit (`git show 9783f286`).

## Invariants to attack
1. The steward never removes, trashes or rewrites a file by any route except
   `DeleteDuplicatesFlow`. Look for `FileManager` remove/trash/move,
   `unlink`, `rename` or calls into other MediaOps delete lanes reachable from a steward
   card, skip, or "done" action.
2. What a card *shows* as the copy that stays is the copy the planner will
   actually keep (the parity of shown vs. done). A card that says "the copy on X stays"
   while the planner would keep Y is P1 if a person decides on that basis.
3. A junk/event card can't sweep in a clip that has a person's decision, a
   Read-only volume's file, or an archive copy (the steward's rule 2 gate, `e713415b`
   moved it off-main: check that the gate result can't be stale when the action runs).
4. DeviceID: grep the whole repo for every remaining `st_dev`, `UInt64(` on a
   device field, and `.deviceIdentifier`/`systemNumber` conversion that does
   NOT go through `DeviceID.from`. A sign-extension mismatch between two sites
   makes "same drive" comparisons false, which feeds the two-drive survivor rule.
   This grep is the one place you may read outside the files above.

Out of scope: wording, layout, ranking quality of the Events lane.
