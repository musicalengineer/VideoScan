# Codex review — Migrate safe-words + removal proof/reservation — round 3

- Range: `main..fix/adversarial-p2-2026-10-26`
- Credits spent: unavailable
- Tokens: 142361
- Finding count: 1
- Verdict: block — adoption can still invite retirement while changed source bytes remain uncopied.
- Run: 2026-10-26T18:36:51Z (cycle #154, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 1  
Verdict: block — adoption can still invite retirement while changed source bytes remain uncopied.

1. **P0 — Adoption proves the destination against a stale source digest.** [VideoScanModel+Relocate.swift:714](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-aec4f835eeb481697/VideoScan/VideoScan/MediaOps/VideoScanModel+Relocate.swift:714) reads the stored source SHA-256 but never checks that it still describes the source. The source path has already been rewritten to the destination at line 398.

   **Reproduction:** catalog and hash A; place identical bytes at its destination; then overwrite source A with different, same-size bytes. Leave the catalog unchanged. Add C with a genuinely proven backup. Reconciliation adopts A’s old destination because its partial hash matches the stored value. The fresh destination SHA matches A’s old SHA, yielding `provenAdoptedCount = 1`, zero attention, and “Your files are safe … you can retire.” A’s changed bytes exist only on the source drive.

   **RED recipe, not executed:** adapt `aSizeOnlyAdoptionNeverInvitesRetire`: hash A, write its original bytes to the destination, then overwrite source A before Migrate. Require `adoptedCount == 1`, `provenAdoptedCount == 0`, and `invitesRetire == false`.

   Preserve the source path and fixity before adoption and validate the source evidence. This requires the agreed live-stat check; it does not challenge the accepted stored-digest policy.

Closing-pass F1’s original size-only recipe is fixed, but its invariant remains open above. **F2–F5 are closed by inspection**, with the archive-replacement, alias and frozen-junk regressions also passing.

- `RelocateSummary.swift` — read, no findings in count/headline logic.
- `RelocateSummarySheet.swift` — read, no findings in scoped headline behavior.
- `VideoScanModel+TrashSelection.swift` — read, no findings.
- `CatalogKnownCopies.swift` — read, no findings.
- `CatalogContent+Table.swift` — read, no findings.
- `AdvReview20261026Tests.swift` — read, no findings.
- `AdvReview20261026TrashTests.swift` — read, no findings.
- `RelocateSummarySheetTests.swift` — read, no findings.

**Validation:** 37 tests across 6 scoped suites passed, Debug, zero failures. The 19 mechanical call-site edits retain concrete outcome assertions. Tracing included summary producers and removal callers required by the brief. Reviewed `2a5bcde69`; worktree remains clean.

## Brief

# Codex review brief — Migrate safe-words and ⌘⌫ only-copy re-check at the move (data-risk, rule 10)

**Workflow in one sentence (Rick's words):** "never lose media" — the app never tells Rick a drive can be retired unless every file on it was proven copied, and ⌘⌫ never moves the last known copy of a family video, even if another copy disappeared after he confirmed.

**Round 3: your closing pass (docs/reviews/codex/codex-review-adversarial-p2-closing-2026-10-26.md, block/5) is answered by `2a5bcde69`: adoption needs a fresh full hash matching the source SHA-256; git's racily-clean rule in `ContentFixity.describesFileNow`; archive-only survivors hashed fresh at the move under reservation; `RemovalReservations` keyed by st_dev+st_ino with leaving/relied-on states, survivors pinned by ⌘⌫, Cleanup, Prune, Delete Duplicates, and `DerivativeOutputPublish.trashThenTake` covered. Known gap, Rick's call, do not report: stamped survivors are proven by stored SHA-256 + live stat (racily-clean), not a fresh re-hash at each move. Verify the five findings closed (focus `975580867..2a5bcde69`); new findings only if data-loss risks.

(Earlier context:) This is the closing pass on YOUR cycle #150 (docs/reviews/codex/codex-review-adversarial-p2-2026-10-26.md, block/5).** Fixes: `26d7714eb` F1/F2/F5 (retire words only on a backup proven by stored whole-file SHA-256 on both sides + `describesFileNow` live stat — not a re-hash; `ContentCopyProof`; `manuallyDeletedCount` in needs-attention; Aging witnesses never prove a backup, `VolumeSafety.isSafe` itself unchanged), `103c0cffc` F3 (identity = SHA-256 only; offline copies don't count; archive copies through the same survivor rule; survivor stat re-checked off-main in `beforeRemoval` just before Trash), `975580867` F4 (process-wide `RemovalReservations`, lock-owned path set; every door through the one Trash engine plus Delete Duplicates' own worker reserves from proof through move and refuses a reserved survivor). Verify each fix closes your recipe; attack the stat-instead-of-rehash compromise (can `describesFileNow` be satisfied by changed bytes?), the archive leg's "regular file, exact size" proof, path-spelling gaps in the reservation (case-fold, firmlinks, symlinks, hard links), and any removal door that bypasses the reservation. Report new findings only if they are data-loss risks.

**Range:** `main..fix/adversarial-p2-2026-10-26` (focus `1aeed5dce..975580867`) · **Worktree:** `/Users/rickb/dev/VideoScan/.claude/worktrees/agent-aec4f835eeb481697` (read-only for you)

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
