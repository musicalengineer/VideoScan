# Codex review — Cutover B2.5 + B2.6 final closing pass

- Range: `4a91fdb7f..2a4d1abc1`
- Credits spent: unavailable (metering not exposed)
- Tokens: 34954
- Finding count: 1
- Verdict: fix — both exact B2.4 findings are closed, but same-ID replacement bypasses the durability protection.
- Run: 2026-10-18T05:41:34Z (cycle #108, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (metering not exposed) | Finding count: 1

Verdict: fix — both exact B2.4 findings are closed, but same-ID replacement bypasses the durability protection.

1. **B2.4 unsaved old-record edit — CLOSED.** [CatalogPurge.swift:79](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/VideoScanModel+CatalogPurge.swift:79) calls [commitBeforeReplacing:290](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:290) before inheritance or retirement. Failure retains both records.

2. **B2.4 attestation deletion ignores label — CLOSED.** [LivePending.swift:161](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+LivePending.swift:161) matches the key plus `label IS ?`. B2.6 similarly matches the full people row, including confirmation date.

**New P1 — same-ID replacement can discard an accepted edit.** [CatalogPurge.swift:77](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/VideoScanModel+CatalogPurge.swift:77) replaces the record immediately when IDs match, skipping both the pre-commit and inheritance.

**Failure scenario:** retain a detached snapshot with the same ID/path/digest, edit the live record’s notes, then pass that stale snapshot to `placeRecord` before debounce; the edited object leaves `records` without its new notes ever reaching SQLite or history.

Apply save-or-refuse protection to distinct objects with matching IDs too. This is a direct function-level counterexample; production caller reachability was not established within the permitted scope.

**Durability guarantee: refuted at the `placeRecord` boundary.** That counterexample requires neither a crash, explicit loss authorization, nor a declared value clash.

Six extracted-production-SQL checks passed in SQLite memory, covering both commit orders for relabel/removal and redate/removal, including NULL labels. Remaining listed production files and all four test files: **read, no findings**. Swift/app tests were not run under the no-files constraint. No files written.

## Brief

# Codex brief: cutover B2.5 + B2.6 — final closing pass on the SQLite write side (2026-10-18 pre-dawn; data-risk)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~500 words.

**Your B2.4 pass:** `docs/reviews/codex/codex-review-cutover-b2-4-closing-pass-2026-10-18.md` (open: unsaved old-record edits lost when a same-digest heir lands; attestation delete ignores the label). **The fixes:** B2.5 (`8c31e5b16`: placeRecord commits the old record first or keeps both; attestation delete matches key+label) and B2.6 (`889c137a4`: people delta on full rows), range `4a91fdb7f..HEAD` on main. Files under `VideoScan/`: app `VideoScan/Catalog/CatalogCommitter.swift` (`commitBeforeReplacing`), `Catalog/VideoScanModel+CatalogPurge.swift` (`placeRecord`, `keepBoth`), `Catalog/CatalogReplacedRecord.swift`; Core `VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+LivePending.swift` (attestation + people deletes), `Commit/CatalogCommitBody.swift` (people as CatalogSetDelta), `Commit/CatalogSharedCurated.swift` (`peopleRows`), `Import/CatalogRecordDTO+Rows.swift`; tests `VideoScanTests/CatalogCutoverB25Tests.swift`, `CatalogCutoverB26Tests.swift`, Core `Tests/VideoScanCoreTests/Store/CatalogCommitB25Tests.swift`, `CatalogCommitB26Tests.swift`.

**Do only this:** (1) your two B2.4 findings: CLOSED (file:line) or OPEN. (2) at most TWO new P1 findings (a lost accepted edit) with a one-line failure scenario. Known and declared, NOT findings: two copies relabelling one attestation or re-dating one person to different values in one 2 s window (last writer); reject-vs-redate of the same name leaves both rows (a policy question for Rick). Confirm or refute: after the flip, an edit accepted by the app is never lost except by a crash inside the 2 s debounce, an explicit 'Quit and lose N', or the declared same-window value clashes above.
**Do not explore outside the files listed above and their tests.**

## Closed

Closed by `b9625577d` at 2026-10-18T05:48:45Z. closed by the next batch; chain ended at B2.7
