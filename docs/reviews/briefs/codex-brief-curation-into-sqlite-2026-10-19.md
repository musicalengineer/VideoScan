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
