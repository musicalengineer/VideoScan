# Codex review — Migrate safe-words + trash only-copy re-check (adversarial P2 2026-10-26)

- Range: `main..fix/adversarial-p2-2026-10-26`
- Credits spent: unavailable
- Tokens: 137116
- Finding count: 5
- Verdict: block — retirement assurances and the per-file Trash gate still accept unproven safety.
- Run: 2026-10-26T16:56:12Z (cycle #150, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 5  
Verdict: block — retirement assurances and the per-file Trash gate still accept unproven safety.

1. **P0 — “Checksum-verified” backups were only stat-checked.** [RelocateSummary.swift:189](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-aec4f835eeb481697/VideoScan/VideoScan/MediaOps/RelocateSummary.swift:189) trusts `safelyBackedUpCount`. Its producer counts witnesses matched by stored partial MD5; `RelocateReconcile.WitnessProof.vouches` checks presence, size and independence, without hashing their current bytes.

   **Reproduction:** catalog identical A/B on separate drives, then overwrite B with different same-size bytes. Migrate A: B still qualifies, nothing copies, and the headline says “checksum-verified” and invites retirement.
   
   **Regression:** extend the real all-safe fixture with that overwrite; assert retirement is withheld and A is copied or reported unproven.

2. **P0 — Missing sources fall outside all four attention buckets.** [RelocateSummary.swift:94](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-aec4f835eeb481697/VideoScan/VideoScan/MediaOps/RelocateSummary.swift:94) omits `manuallyDeletedCount`. Marking a source missing proves no surviving copy.

   **Reproduction:** rename and modify a cataloged file on the source so reconciliation cannot match it; its old path becomes “Missing,” while the actual file remains uncopied. One other successfully backed-up file produces “Your files are safe … Everything’s accounted for.”
   
   **Regression:** summary with `safelyBackedUpCount = 1`, `manuallyDeletedCount = 1`, other attention counts zero; assert `invitesRetire == false`. The buckets are disjoint, but not exhaustive.

3. **P1 — The new Trash gate does not establish a live SHA-256 copy.** [VideoScanModel+TrashSelection.swift:266](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-aec4f835eeb481697/VideoScan/VideoScan/MediaOps/VideoScanModel+TrashSelection.swift:266) delegates to [CatalogKnownCopies.swift:42](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-aec4f835eeb481697/VideoScan/VideoScan/MediaOps/CatalogKnownCopies.swift:42), which accepts partial MD5 or sampled signatures—even with conflicting full digests. The survivor predicate checks catalog state, not file existence/reachability. The archive fallback also bypasses the retired-root predicate.

   **Reproduction:** confirm A while B exists; move B elsewhere without updating its catalog row; apply A’s confirmed plan. A still moves unwarned. Matching sampled identities without SHA-256 also qualify.
   
   **Regression:** adapt `aCopyThatBecameTheOnlyOneAfterTheConfirmationIsHeld` to move B on disk instead of setting `purgedAt`; require A to remain. Add conflicting-SHA and offline-witness cases.

4. **P1 — Concurrent batches can still move both copies.** [VideoScanModel+TrashSelection.swift:229](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-aec4f835eeb481697/VideoScan/VideoScan/MediaOps/VideoScanModel+TrashSelection.swift:229) installs an empty `beforeRemoval`; `junkTurn` then awaits detached disk work. `leaving` belongs only to that batch.

   **Reproduction:** confirm separate batches for identical A and B before either starts. Pause A’s disk operation before its move; run B’s batch to completion; resume A. Each authorizes against the other, and both move.
   
   **Regression:** use a barrier in the disk seam and assert at least one source survives. The window has no bounded duration. Shared exclusion/reservation must cover proof through removal; moving the check closer alone does not close it. Delete Duplicates has only its own reentry flag; Prune shares no such exclusion. Migrate itself preserves source files.

5. **P2 — Aging-only backups still invite retirement.** [RelocateSummary.swift:95](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-aec4f835eeb481697/VideoScan/VideoScan/MediaOps/RelocateSummary.swift:95) relies on `degradedOnlyCount`, but `VolumeSafety.isSafe` accepts `.aging`. Those witnesses populate `safelyBackedUpCount`, leaving degraded count zero—contrary to invariant 1 as written.

   **Regression:** change the all-safe fixture’s sole witness to `.aging`; assert no retirement invitation. The existing ranking test explicitly treats aging witnesses as safe.

Existing named suites passed: **22 tests / 4 suites, Debug, zero failures**. The regression recipes above were not executed as new RED tests; no repository files changed.

`CatalogTrashTurnCopies` is main-actor confined. Array replacement bumps the revision; cached row references observe in-place mutations. I found no unsafe stale-cache case. The 19 edited call sites retain concrete outcome assertions.

- `RelocateSummarySheet.swift` — read, no findings.
- `CatalogContent+Table.swift` — read, no findings.
- `AdvReview20261026Tests.swift` — read, no findings.
- `AdvReview20261026TrashTests.swift` — read, no findings.
- `RelocateSummarySheetTests.swift` — read, no findings in the edits; existing aging expectation supports finding 5.

Tracing extended only to summary producers, identity helpers and removal callees needed to resolve the stated invariants.

## Brief

# Codex review brief — Migrate safe-words and ⌘⌫ only-copy re-check at the move (data-risk, rule 10)

**Workflow in one sentence (Rick's words):** "never lose media" — the app never tells Rick a drive can be retired unless every file on it was proven copied, and ⌘⌫ never moves the last known copy of a family video, even if another copy disappeared after he confirmed.

**Range:** `main..fix/adversarial-p2-2026-10-26` (two commits: `3ecd21c28`, `1aeed5dce`) · **Worktree:** `/Users/rickb/dev/VideoScan/.claude/worktrees/agent-aec4f835eeb481697` (read-only for you)

**Origin:** nightly adversarial review 2026-10-26 (P2 ×2): a Migrate that copied nothing still said "Your files are safe … you can retire <drive>"; ⌘⌫ checked "the only copy we know of" before its alert but at the move only logged the answer.

**In scope:**
- `VideoScan/VideoScan/MediaOps/RelocateSummary.swift`, `RelocateSummarySheet.swift` — `RelocateSummaryHeadline`, `needsAttentionCount`
- `VideoScan/VideoScan/MediaOps/VideoScanModel+TrashSelection.swift` — `trashSelectedRecords(_:confirmed:fileOperation:)`, the per-file `authorize` step
- `VideoScan/VideoScan/MediaOps/CatalogKnownCopies.swift` — `CatalogTrashTurnCopies`, `candidates`
- `VideoScan/VideoScan/Catalog/CatalogContent+Table.swift` — the confirm path
- Tests: `AdvReview20261026Tests.swift`, `AdvReview20261026TrashTests.swift`, `RelocateSummarySheetTests.swift`

**Invariants to attack:**
1. No headline says "safe" or invites retiring while any file on the drive lacks proof (failed copy, still at path, unmarked, backed up only on aging/retired drives). Are those four buckets exhaustive and disjoint? Any summary state that falls through to the safe words?
2. At each file's turn, a file is moved only if it was in the confirmed plan AND (it was warned as an only copy, OR another live, reachable, non-retired copy with the same identity — whole-file SHA-256 — still exists that is not itself moved earlier in this batch). Construct a batch where two copies vouch for each other and both move; a copy counted as surviving that is on a retired/offline drive, unhashed, or matched by a weaker identity than SHA-256; a stale `candidates` cache (mutation without a `catalogMutationRevision` bump).
3. The window between the authorize check and the off-main disk move: can another door (Find Duplicates, Prune, Migrate) remove the other copy there? How large, and is it acceptable or should the check sit under a lock the other doors also take?
4. Swift 6 isolation of `CatalogTrashTurnCopies` (per-batch class): who mutates it from which executor?
5. Do the 19 mechanically edited test call sites still test what they tested (passing `catalogTrashPlan(for:)` could make a test pass vacuously)?

**Evidence already run:** RED seen per test (tables in commit messages); touched suites 113 tests / 21 suites green; sensor lane GREEN 574; gauntlet manifest errors [].

**Known and accepted (do not report):** media matrix not extended (gate reads the catalog only; `OneEngineMediaMatrixAndScaleTests` green); P3s from the same nightly report.

**Output contract:**
```
Credits spent: <amount> | Finding count: <N>
Verdict: merge | fix | block — <one sentence>
```
Then findings ranked by data-loss risk, each with `file:line`, a reproduction, and a RED test where possible. For every in-scope file with nothing to report write "read, no findings."
