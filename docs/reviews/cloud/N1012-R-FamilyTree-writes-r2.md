Brief: N1012-R-FamilyTree-writes (second pass) | Source: main@4e3210e5 | Wall clock: ~30 | Files read: 9
Finding count: 1 (REAL 1 / NEEDS-MAC 0 / NOISE 0)
Verdict: All four first-pass findings are fixed, and the fixes hold under attack. The damaged-file set-aside, the lore kept through a re-run and the commit-on-close are all sound, and the CyberBrainWriter split preserved behaviour. One gap remains in the new rulings compare-and-swap: it merges whole rulings per record. If a hand edit and a Hide land on the **same** record, the hand-edited note and "verified" are replaced by the tab's stale copy.

## Why a second pass
- This row ran on 10-06 (`N1012-R-FamilyTree-writes.md`, on main; ledger: 4 confirmed, including a P1, fixed on `fix/family-writes-n1012`, merged `03a0dab7`). Rick named it again on 10-11, so this pass attacks **what changed since** (`ebcd2f09..4e3210e5`) under `FamilyTree/` and the CyberBrain / identity writers. It does not repeat the first report.
- **Commits in range:**
  - `dfe52f57`, `b52e0746`: rulings never saved over a damaged file; stale snapshot compare-and-swap.
  - `f7a9b6b9`, `f78f26ef`: the "not of" sidecar is set aside; real errno.
  - `86e6a7f8`: lore survives a re-run.
  - `68ce5316`: closing the sheet saves lore.
  - `7b919780`: CyberBrainWriter split into six files.
  - `d8aac4c9`: tree cards no longer rebuilt on catalog publishes (#307, view-only).
- **Read:**
  - `FamilyIdentityDecisions.swift` (`record`, `loadWithRevision`, `save`, `rebasedOntoCurrentFile`, `moveDamagedFileAside`)
  - `FamilyTreeLiveModel.setRecordHidden` (:2364-2420) and its rulings loads (:596, :815-853, :1264)
  - `FamilyAssetStore.excludePhoto` / `loadExclusionForUpdate` / `setAsideDamagedExclusion` (:1055-1130)
  - `ResearchPersonSheet.swift` model (`run`, `apply`, `close`, `commitPendingLore`, `commitLore`, :100-300)
  - `CyberBrainWriter+Sources.swift`, `+Testimony.swift` (research-finding idempotence)
  - the `7b919780` diff, line-multiset compared
  - `FamilyIdentityDecisionsDamagedFileTests.swift` (:85-140)

## First pass on current main

| First pass | Status | Attacked, and why it holds |
|---|---|---|
| F1 P1: Hide saves the rulings snapshot from load time over newer edits | **Fixed for other records**; a same-record gap remains (r2-F1) | `save` re-reads the file. If the revision changed it applies only this value's diffs against what it loaded (`rebasedOntoCurrentFile`, :363-380), and it refuses when the file is now unreadable. Both windows' models run on the main actor, so two saves cannot interleave in-process. Pinned: `qaRedAFileFixedByHandAfterLoad…` and `aStaleSnapshotOverAFileThatIsNowUnreadableIsRefused`. Both use **different** records. |
| F2 P2: a damaged "not of" sidecar is read as empty and overwritten | **Fixed** | Under `exclusionLock`, a present-but-unreadable sidecar is moved aside through the shared no-clobber `DamagedFileSetAside.move` before anything is written. If the move fails, the write is refused (:1096-1130). The set-aside copy keeps the old rulings, and the 🔴 log line says how to restore it. |
| F3 P2: lore typed on a finding a re-run drops is lost | **Fixed** | `apply` captures `editedLore` **after** the await, on main, and `merge(fresh:keeping:)` keeps those findings. `commitLore` on a missing finding now sets `errorMessage` and keeps the draft, instead of "saved" (:244, :255). |
| F4 P3 NEEDS-MAC: lore committed on Return only | **Fixed for Close / Esc / window close** | `.onDisappear { model.close() }` commits every edited draft and then writes any uncommitted words to the log. **Residual (not counted):** whether `onDisappear` fires for a sheet when the app quits (⌘Q) needs the Mac. If it does not, lore typed and then quit is still lost. Check: type lore, ⌘Q, relaunch. |
| CyberBrainWriter split (`7b919780`) | **Behaviour preserved** | A line-multiset diff of the removed vs added lines shows only extraction: `appendConversationSource`, `appendTestimonySource`, `appendCaptionSources`, `resolveCaptionSubjects`, `resolveTestimonySubject`. The told-by source keeps its contains-check in both paths, the research-finding idempotence early return is intact (+Testimony.swift:134-141), and the save still goes through `+Persistence`. Six characterization tests landed with it. |

## Finding

### N1012-R-FamilyTree-writes-r2-F1: P2 · REAL · The rulings compare-and-swap merges per record, so Hide or Unhide on a record Rick just hand-edited replaces his note and "verified" with the tab's stale copy
- **Symbols:**
  - `FamilyTreeLiveModel.setRecordHidden`, FamilyTree/FamilyTreeLiveModel.swift:2370-2380. It builds the new ruling from the **in-memory** copy: `var updated = identityDecisions; let existing = updated.decision(for: key); updated.record(.init(key:, verified: existing?.verified ?? false, duplicateOf: existing?.duplicateOf, hidden: true, note: note ?? existing?.note))`.
  - `FamilyIdentityDecisions.rebasedOntoCurrentFile`, VideoScanCore/FamilyIdentityDecisions.swift:373-376. For every key where `decisions[key] != base.decisions[key]` it does `merged.record(mine)`, and `record` (:197-199) replaces the **whole** decision (`decisions[decision.key] = decision`).
- **Scenario (the documented workflow; the code says in three places that Rick edits this file by hand):**
  1. The tree is open. The tab loaded the rulings when record X had no ruling, or an old one.
  2. Rick opens the rulings file in an editor and gives X a note ("same person as the census entry, checked 1930 roll") and `"verified": true`. He saves it.
  3. Back in the tab he clicks Hide on X. `existing` is the stale value (nil), so `mine = {hidden: true, verified: false, note: nil}`.
  4. `save` sees the revision changed and rebases. X differs from what the tab loaded, so `merged.record(mine)` replaces the hand-edited X. The note and `verified` are gone. The log even says "applied this change on top of the current file", which reads as if nothing was lost.
  - **Unhide variant:** the same steps with X already hidden in the stale copy. `existing.hidden = false` on the stale value writes the stale note over the hand edit.
- **The guard that would make it false, and why it doesn't hold:** the compare-and-swap protects records the tab did **not** touch. The tests use different keys (`mary` vs `TEST-0002/3`). For the touched record there is no field-level merge, and no conflict refusal like Research's lore CAS (`onDisk != start && onDisk != draft` refuses, ResearchPersonSheet.swift:247). So a second-writer edit to the same record is silently overwritten. A reload would refresh the copy, but tree loads are keyed on `sourceRevision`, which does not include the rulings file (first pass F1).
- **Why P2:** the first pass rated the whole-file version P1. This residue is narrower: it needs the same record in both edits, between two tree loads. But what is lost is still Rick's hand research (a note, a verification), with no backup and no message.
- **Pinning test (fails today; add to `FamilyIdentityDecisionsDamagedFileTests`, Core, runs on Linux):**
  1. `save` `{X: verified false}`, then `var stale = load(from: dir)`.
  2. Write by hand `{X: verified true, note "hand"}` with a plain `save` from a fresh value.
  3. `stale.record(.init(key: X, verified: stale.decision(for: X)?.verified ?? false, hidden: true, note: stale.decision(for: X)?.note))`, then `try stale.save(to: dir)`.
  4. Expect X on disk to have `hidden == true`, `verified == true` and `note == "hand"`. Today it has `verified == false` and `note == nil`.
  - Sibling test: the refuse-on-conflict shape, if Rick prefers a refusal over a field merge.
- **Fix direction:**
  - Make Hide a **delta applied to the current file**, not a stale value: `save(to:applying: (inout FamilyIdentityDecisions) -> Void)`, which re-reads under the compare-and-swap and runs `{ $0.setHidden(true, for: key, note:) }` on what is on disk now.
  - Or refuse when the touched record changed on disk (the lore pattern).
  - Either way it is the read-modify-write shape that N1013's top refactor (one helper for hand-curated JSON files) and the playbook's job 9 describe. In C++ terms: a transaction that takes a mutator, not a whole new row computed from a cached copy.

## Not covered
- **FamilySearch pull / refresh writers:** no commits touched them in range, so they were not re-read.
- **`PersonFactOverlayStore`, `FamilyTreeBookmarks`, research dossier store:** unchanged in range, not re-read. N1013-F2 (bookmarks) is tracked there.
- **The #307 change (`d8aac4c9`):** view-only, not reviewed for writes.
- Nothing was built or run.

## Blockers & environment
- **Branch:** README rule 3 names `cloud/N1012-R-FamilyTree-writes`. This session may push only to its designated branch, so the report is on `claude/compassionate-babbage-kn9mbj`.
- No tool failures.
