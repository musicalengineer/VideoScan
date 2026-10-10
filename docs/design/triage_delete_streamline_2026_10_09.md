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

## 9. Revisions after the codex design review (2026-10-09, verdict "revise", 9 findings)
Review: `docs/reviews/codex/codex-design-triage-delete-2026-10-09.md`. Manager verified F3, F5
and F7 against the source. These override §3–§7 where they conflict.
- **R1 (F1) Junk acts on a frozen snapshot**: IDs + expected paths + file identities + sizes
  frozen when the confirmation opens; execute only that; at each file's turn re-check
  Confirmed status, identity, reachability, protections; any change → a named hold. Never act
  on whatever now sits at a counted path. Per-file authorization freshness (today it is once
  per batch, VideoScanModel+JunkDelete.swift ~282).
- **R2 (F2) Duplicates run the exact reviewed plan**: new job entry point taking the reviewed
  `DeleteDuplicatesPlan` (today a fresh job re-plans, DeleteDuplicatesJob.swift ~925);
  partition into sequential per-volume plans; one fixed keeper per group; no keeper is ever a
  target (aliases included).
- **R3 (F3) Trash-only is an execution rule**, not a button removal: junk `.permanent` /
  `removeItem` and the duplicates `.permanent` disposal (DeleteDuplicatesJob.swift ~395, ~458)
  become unexecutable in these flows, including resumed legacy plans; old values stay
  decodable for history. Trash failure never falls back to unlink; a quarantined/stranded
  file gets a visible recovery action.
- **R4 (F4) Invariant scope**: keeper proof (§6.1) applies to duplicates only (junk may be
  unique — a human confirmed it). Wording: "nothing is DISPOSED of unless proven" (the
  duplicate path quarantines before hashing). Name the execution gates for network mounts,
  archive-backup drives, longer-than-master and A/V halves; keeper precedence is election, not
  protection.
- **R5 (F5) Survival rule — Revised by Rick 2026-10-09 evening: keep ONE proven copy; no
  per-file ticks; pairs included; proof at the move is the safety.** ("why do I need to
  checkbox every file … when I select delete dups it should do what it said, ensure it is
  only deleting extras.") A bulk Delete Duplicates run (fresh or resumed) moves every proven
  extra; `preselected` is UI information only and gates nothing. Supersedes the "2 copies
  not pre-checked" rule below and codex delete-engines F6.
  Earlier ruling (same day, superseded): **keep ONE verified copy.** "When we have
  5 copies, it should be easy to move them to Trash." Groups with 3+ copies: extras
  pre-checked, bulk "Move selected extras to Trash" is the fast path. Groups with exactly 2:
  allowed, but NOT pre-checked (a deliberate tick — "it is ok to ask or compare"). The single
  keeper must still be proven at disposal time (read in full / fixity, digest match, not an
  alias of the target). Was: today Trash needs ≥ 2 verified copies to
  REMAIN (`minimumForTrash = 2`, DeleteDuplicatesPlan.swift ~557), so "keep 1" is refused:
  with 2 copies, nothing moves. Options: keep the 2-remain rule (the UI says "keeps 2"), or
  allow 1 verified keeper for Trash (Trash is the safety net). Digest/identity verification
  is unchanged either way.
- **R6 (F6) One outcome per requested ID**, including preflight exclusions (an all-protected
  selection today returns attempted 0 with no reasons); lazy lists, never truncated reasons;
  rows leave only after confirmed success.
- **R7 (F7) Accounting**: frozen requested set = moved + held + failed + missing + cancelled
  (mutually exclusive). Junk bytes = sum of moved files' sizes (today scaled by success ratio,
  JunkDeleteAction.swift ~99 — wrong when sizes differ). Label "moved to Trash", not "freed".
- **R8 (F8) Undo → "Open Trash"** in v1; real put-back is a separate feature later.
- **R9 (F9) One selection authority**: checkboxes are the truth; volume chips bulk-toggle
  eligible checkboxes; the button reads "Move selected extras to Trash". v1 CUTS: arbitrary
  keeper override (only eligible higher-ranked keepers), custom Undo, skipping the confirmation
  for small selections, retiring the Excess pane.

## 10. "Copies & Advice…" — one file, fully explained (Rick 2026-10-09)
Rick: "a right-click on a specific file in Triage telling me number of copies, which ones to
keep, which to delete, lives in archive, same event, etc — all explained on one file; then once
I see the analysis I can feel confident to delete."

First item of the Triage right-click (and the Catalog row menu): **Copies & Advice…** opens one
read-only card for that file, built off-main from existing engines (no new analysis):
```
Brockton_Xmas_1994.mov  · 41 GB · DNxHD · 1:12:04
ADVICE  Safe to move to Trash — the archive holds a verified copy, and 2 more copies exist.
EXACT COPIES (same bytes)                                  4 in all
  KEEPS  FamilyArchive  …/1994/Brockton_Xmas_1994.mov   archived ✓ fixity checked 10/2
         RAID_A         /Projects/FCP/…                 stays (unchecked)
  ►THIS  LaCie_8TB      /Imports/old/…                  can go
         SanDisk_2TB    /Shorts/…                       can go
SAME FOOTAGE (not the same bytes)                            2
  Brockton_Xmas_1994_access.mp4   access copy (HEVC) — derived from the archive copy
  Brockton_Xmas_clip03.mov        4 min clip — looks like part of this tape
WHY IT WAS FLAGGED   duplicate of an archived file (Content Steward, 10/8)
[Move this copy to Trash]   [Move all 2 extras to Trash]   [Keep this one]
```
- **Sources (reuse):** exact copies + archive status → `CopyFamilyAssessor` / the duplicate
  engine's verified groups; keeper + why → `DuplicateKeeperPolicy` (archive › RAID › HDD › SSD,
  never offline); same footage → `FootageGrouping` (re-encodes, transcodes, derivations); "why
  flagged" → Steward evidence / disposition history.
- **Advice in plain words**, one of: "Safe to move to Trash — …" / "Keep — this is the only
  copy" / "Keep — this is the archive copy" / "Check first — copies match by sample only" /
  "Connect <drive> to decide".
- **Buttons go through the same door as §5** (frozen set, one confirmation, result banner).
  "This copy" is never the keeper; the archive copy never shows a delete button.
- Clip-of-master ("looks like part of this tape") appears only when the future containment
  detector exists; until then the section shows same-length footage only.
- Open in < 1 s for one file: O(group), never O(records) per open (needs the duplicate
  groups and footage groups already computed; if stale, say "as of <time> — Refresh").

## 11. Queued after the Duplicates view (Rick, 2026-10-09)
- **Archive cleanup (ruled: allowed with explicit per-item OK).** Rapid promoting earlier put
  redundant versions into FamilyArchive (one CapeCod hour has 7: DV original, 3 FFV1, 2 HEVC,
  1 ProRes). Recommend a keep set: the original capture + one preservation + one access + one
  edit copy; everything else is offered, one confirmation per item, Trash on the archive
  volume. MUST keep the 00_Index manifest, journals and the ledger consistent. Data-risk:
  `/safety-critical` + codex. Background jobs never do this on their own.
- **Differences & Advice in the Same Footage window**: every member vs the reference (exact
  copy / different container / re-encode codec→codec / different edit / longer), codec · size
  · drive · archived, each member's Verify verdict in plain words, and a recommendation line
  with "Move recommended to Trash…".
- **Codec ladder** (a data table): original capture (kept whatever the codec — DV from a
  digital tape is bit-perfect) → preservation (FFV1) → edit (ProRes/DNx) → access (HEVC/H.264/AV1)
  → legacy derivatives to retire (Cinepak, Sorenson, MPEG-1, RealVideo, WMV, DivX/Xvid, 3GP,
  low-res MJPEG, Indeo, FLV…). Old derivatives go when a better version exists; a unique file
  is always kept (Repair can modernise it).
- **Only-copy badge** in Triage/Catalog ("this is the only copy — keep").
- **Purchased movies** (FairPlay DRM, iTunes purchase metadata, .m4v under Movies/TV) →
  suggested "not family media".
- **Footage Spectrum**: a plain-word verdict line per file (from Verify) instead of colours only.
