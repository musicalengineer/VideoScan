# Codex review — Curation into SQLite

- Range: `7da77037b..b594988fd`
- Credits spent: unavailable (meter not exposed)
- Tokens: 74124
- Finding count: 4
- Verdict: fix — `b594988fd` still permits curation loss and a second writable store.
- Run: 2026-10-20T01:11:20Z (cycle #113, tools/codex_review.py)

## Closure (2026-10-20, merged 24d3566ac)

All four P1s fixed in `6bfc76ce2`, pinned in `VideoScan/VideoScanTests/CurationAuthorityCodex113Tests.swift` (red before the fix, green after):

1. **P1-1 folder JSON reconciled** — import compares an existing folder's rows with the JSON and reconciles/reports instead of skipping by UUID (pinned in the folder import suite, EventsCatalogBackingTests).
2. **P1-2 put-back stays put back** — `PutBackStaysPutBackTests`; pending/import entries exclude ids already in `ignored_content_put_back`.
3. **P1-3 unknown-digest leaver** — `SplitUnknownDigestHoldTests`; the split holds until every departing member has a durable relationship.
4. **P1-4 authority at the store boundary** — `SideStoreAuthorityTests`; folder/ignore stores refuse JSON writes when SQLite is the authority, including after a launch fallback.

Trial merge on main a8052b7c7: 175 app tests in 45 suites green; core 1,478/1,479 (the one miss, FamilyMap 40k-people timing, passes alone; untouched by this branch). Rick OK'd `ignored_content_put_back` 2026-10-20.

## Codex answer

Credits spent: unavailable (meter not exposed) | Finding count: 4

Verdict: fix — `b594988fd` still permits curation loss and a second writable store.

1. **P1 — Existing folders lose newer JSON metadata during import.** [EventsJSONImport.swift:99](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a376418e34be83ab2/VideoScan/VideoScan/Events/EventsJSONImport.swift:99) skips every folder UUID already in SQLite, without comparing its contents; count verification still passes.
   
   **Failure scenario:** Cutover imports folder A, an older build renames or dismisses A in JSON, then this build launches: SQLite retains A’s old metadata and records the permanent import marker. Those older operations append no decision that replay could recover. Reconcile differing rows or report conflicts before completing import.

2. **P1 — Refused ignore import can reverse an explicit “put back.”** [IgnoredContentStore.swift:389](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a376418e34be83ab2/VideoScan/VideoScan/Catalog/IgnoredContentStore.swift:389) filters fallback JSON entries against **live** IDs, allowing previously put-back entries back into memory; subsequent saving inserts new live rows.
   
   **Failure scenario:** SQLite marks A put back; frozen JSON contains A plus an unimported B; import is refused while held; after release, the next save re-ignores A. Reproduced using the production SQL in memory. Exclude IDs already represented by put-back rows when preserving pending/import entries.

3. **P1 — Split drops an unknown-digest member’s only relationship.** [DuplicateGroupDigestSplit.swift:313](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a376418e34be83ab2/VideoScan/VideoScan/MediaOps/DuplicateGroupDigestSplit.swift:313) clears singleton membership, while [+Likeness.swift:78](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a376418e34be83ab2/VideoScan/VideoScan/MediaOps/DuplicateGroupDigestSplit+Likeness.swift:78) excludes unknown digests; `.pairs` bypasses the connectivity hold.
   
   **Failure scenario:** Split `K(nil, keep), A(shaA), B(shaB)` without footage membership: all leave the copies group, only A↔B is recorded, and K loses its relationship. Hold the split until every departing member has a durable relationship.

4. **P1 — SQLite launch refusal leaves folder write doors targeting JSON.** [CatalogAuthorityFlip.swift:283](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a376418e34be83ab2/VideoScan/VideoScan/Catalog/CatalogAuthorityFlip.swift:283) freezes the main catalog without attaching or blocking the folder store; [EventsDecisionStore.swift:405](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a376418e34be83ab2/VideoScan/VideoScan/Events/EventsDecisionStore.swift:405) still permits JSON publication.
   
   **Failure scenario:** After SQLite-authoritative launch falls back, load the folder store and invoke its drop/write door: JSON changes; recovery skips those changes once an import marker exists. Enforce authority at the store boundary. The writable door is established; outer UI gesture availability was not verified.

**Read, no findings:** `CatalogCommitter.swift`, `EventsDecisionValues.swift`, `EventsCatalogBacking.swift`, `EventsFolderDrop.swift`, `IgnoredContentCatalogBacking.swift`, `IgnoredContentJSONImport.swift`, `VideoScanModel+DuplicateDigestSplit.swift`, `DuplicateDetector.swift` (stamping path), `FootageLikenessStore.swift`, `CatalogFolderRows.swift`, `GRDBCatalogRepository+Folders.swift`, `CatalogDecisionRows.swift`, `GRDBCatalogRepository+Decisions.swift`, `CatalogDecisionTablesSchema.swift`, `CatalogFolderKindSchema.swift`.

Migration SQL passed in-memory preservation, append-only, FK, and rollback checks. Historical tests cover v11 ordinary-open rejection of schema 12; v11 viewer/openReadOnly compatibility remains unverified within scope. No files written; Swift suites were not rerun because they create files.

## Brief

# Codex brief: Rick's curation moves into catalog.sqlite — folders, ignore list, duplicate split + same-footage pairs (2026-10-19 night; data-risk; Rick approved a bundled pass)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~700 words.

**Range:** `7da77037b..worktree-agent-a376418e34be83ab2` (main through `ef70b081b` plus the unmerged branch tip `b594988fd`). The folders port is merged (`cb13f7366`); the duplicate split (`418b8f707`) and same-footage (`9966d642c`) are merged; the decision-tables branch (footage_likeness, ignored list port, schema 11 → 12) is NOT yet merged — review it as the candidate.

**What changed.**
- Folders (confirmed events) moved from `events-decisions.json` into catalog.sqlite (`events`, append-only `event_decisions`, `event_members` rebuilt per touched folder; additive `events.kind`, schema 11). One-time idempotent import at launch, verified by counts; JSON frozen. All writes via `CatalogCommitter.commitSideTables` (was `commitFolders`), applied in memory only after the write succeeds. Refused when read-only / viewer / held / blocked.
- Duplicate groups are digest-pure (same whole-file SHA-256). The split moves non-identical members out; same-footage likeness goes to Find Similar Footage (`copyCheckLikeness`) or, on the branch, to a new pairs table `footage_likeness` (weak / anchored / oldGroup, reasons verbatim), written in one transaction BEFORE any record change; refusal refuses the whole split.
- Ignore list: `ignored_content` (302 rows from the cutover) becomes the store; the 41 JSON-only entries import idempotently by entry id; a same-id/different-content entry is a finding, never a replacement; branch adds `ignored_content_put_back` (append-only) instead of deleting import rows.

**Files (only these; under `VideoScan/VideoScan/` and `VideoScan/VideoScanCore/Sources/VideoScanCore/`):**
- `Catalog/CatalogCommitter.swift` (commitSideTables), `Catalog/CatalogAuthorityFlip.swift` (attach)
- `Events/EventsDecisionStore.swift`, `Events/EventsDecisionValues.swift`, `Events/EventsCatalogBacking.swift`, `Events/EventsJSONImport.swift`, `Events/EventsFolderDrop.swift`
- `Catalog/IgnoredContentStore.swift`, `Catalog/IgnoredContentCatalogBacking.swift`, `Catalog/IgnoredContentJSONImport.swift`
- `MediaOps/DuplicateGroupDigestSplit.swift`, `MediaOps/DuplicateGroupDigestSplit+Likeness.swift`, `MediaOps/VideoScanModel+DuplicateDigestSplit.swift`, `MediaOps/DuplicateDetector.swift` (the group-stamping path only)
- `FootageGroups/FootageLikenessStore.swift`
- `Store/CatalogFolderRows.swift`, `Store/GRDBCatalogRepository+Folders.swift`, `Store/CatalogDecisionRows.swift`, `Store/GRDBCatalogRepository+Decisions.swift`, `Store/CatalogDecisionTablesSchema.swift`, `Store/CatalogFolderKindSchema.swift`

**Evidence already run:** red→green→revert on each change; on scratch copies of the real catalog: folders 18/18 and 42 members verified name by name after the real launch import; split 466 multi-digest groups → 0, 1,623 files left groups, 1,411 pairs kept, 0 lost; ignored 343 = 41 added + 302 present. Merged-main suites green (folders 216, same-footage 102, Folders Only 108).

**Do only this. Attack three invariants:**
1. **No curation decision is lost, silently replaced, or written to a store that is not the authority.** Import idempotence across relaunches and partial failures; in-memory vs committed divergence after a refused write; the old build writing JSON after the import (what happens on the next launch); a crash between the decision append and the member rebuild; viewer/read-only paths that still write.
2. **The split never loses a relationship and never creates delete eligibility.** A file that leaves a copies group must remain a copy elsewhere, in a footage group, or in footage_likeness; nothing reads likeness or footage membership for delete; keeper/disposition carried correctly; idempotent second run.
3. **Schema 12 is additive and safe to ship to the fleet:** migration from v11 with live data, append-only guards, FK behaviour on content removal, a v11 viewer meeting a v12 file.

At most FIVE findings. P0/P1 = a decision lost or replaced, a second writable store, or a delete made eligible. One-line failure scenario each.

Known and declared, NOT findings: no Undo for folder edits; the 1,329 weak pairs need a bulk review UI; #338 (high-water before COMMIT); the quarantine has no door (#339).

**Do not explore outside the files listed above and their tests.**
