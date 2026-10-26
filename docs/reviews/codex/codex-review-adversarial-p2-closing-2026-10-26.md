# Codex review — Migrate safe-words + removal proof/reservation — closing pass on Codex #150

- Range: `main..fix/adversarial-p2-2026-10-26`
- Credits spent: unavailable
- Tokens: 167307
- Finding count: 5
- Verdict: block — retirement assurances and unwarned Trash moves still have reproducible paths that lack a surviving, proven copy.
- Run: 2026-10-26T17:55:56Z (cycle #153, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 5  
Verdict: block — retirement assurances and unwarned Trash moves still have reproducible paths that lack a surviving, proven copy.

1. **P0 — Unproven adoption still falls through to retirement.** [RelocateSummary.swift:109](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-aec4f835eeb481697/VideoScan/VideoScan/MediaOps/RelocateSummary.swift:109) excludes `adoptedCount` from attention; the new proof pass covers only Bucket E. Bucket D can adopt an unrelated file based solely on size when the source has no partial hash: [RelocateReconcile.swift:831](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-aec4f835eeb481697/VideoScan/VideoScan/MediaOps/RelocateReconcile.swift:831).

   **Reproduction:** source A has no stored hash; destination contains unrelated, same-size X. Add source C with a genuinely proven backup. Migrate adopts X for A and proves C. With `adoptedCount = 1`, `provenBackupCount = 1`, and zero attention, it says “Your files are safe … you can retire.” A’s bytes were never copied.

   **RED recipe:** extend `RelocateSummaryProofTests` with that mixed fixture; require the retirement invitation to be withheld. Every outcome contributing to retirement needs proof, including adoption.

2. **P0 — Changed bytes can satisfy `describesFileNow` on HFS+.** [ContentCopyProof.swift:39](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-aec4f835eeb481697/VideoScan/VideoScan/MediaOps/ContentCopyProof.swift:39) accepts the stamp without checking timestamp resolution. Apple’s HFS+ implementation explicitly returns zero nanoseconds for both mtime and ctime. [Apple HFS source](https://github.com/apple-oss-distributions/hfs/blob/main/core/hfs_vnops.c#L1002-L1009)

   **Reproduction:** on HFS+, write and hash a small backup B, then overwrite it **in place**, with different same-size bytes, within the same timestamp second. UUID, inode, size, mtime and ctime can all remain equal. The stored SHA therefore passes `holdsNow()` despite describing different bytes. This affects both retirement and ⌘⌫.

   **RED recipe:** an HFS+ fixture requiring equal before/after stamps and unequal freshly computed hashes, then asserting `ContentCopyProof.proven(...) == false`. The cache policy needs to reject ambiguous stamps or obtain stronger evidence.

3. **P1 — The archive fallback accepts a replaced, same-size file.** [ContentCopyProof.swift:75](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-aec4f835eeb481697/VideoScan/VideoScan/MediaOps/ContentCopyProof.swift:75) checks only regular-file status and length when the claim has `archiveFixity` without usable `contentFixity`.

   **Reproduction:** confirm A while archive B has the matching stored digest. Replace B with unrelated same-size bytes, leaving its catalog row unchanged. A’s stamp passes; B’s `lstat` passes; A moves unwarned. Archive read-only policy does not establish the identity of the file currently occupying that path.

   **RED recipe:** adapt `aCopyRewrittenOnDiskIsNotProvenAtTheMove`, giving B only `archiveFixity`. Require A to remain and the Trash seam to receive nothing. Require stamped evidence or a fresh hash for this fallback.

4. **P1 — An alias bypasses the reservation and both copies can move.** [RemovalReservations.swift:34](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-aec4f835eeb481697/VideoScan/VideoScan/MediaOps/RemovalReservations.swift:34) keys by standardized, lowercased path, while [VideoScanModel+TrashSelection.swift:442](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-aec4f835eeb481697/VideoScan/VideoScan/MediaOps/VideoScanModel+TrashSelection.swift:442) tests each candidate’s spelling. `standardizingPath` can retain symlink components. [Apple documentation](https://developer.apple.com/documentation/foundation/nsstring/standardizingpath)

   **Reproduction:** catalog physical copies A and B, plus another row naming A through a directory symlink. Confirm separate A/B batches. Park A after proof, before its move. B rejects reserved A’s ordinary spelling but accepts its unreserved alias; the alias’s stamp remains valid. B moves, then A resumes and moves.

   **RED recipe:** add the alias row to `twoBatchesForTwoCopiesNeverMoveBoth`; retain its assertion that at least one physical copy survives. Reservations must recognize physical identity across aliases.

5. **P1 — Reserving the target does not protect its survivor from other removal doors.** [JunkDiskTurn.run:561](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-aec4f835eeb481697/VideoScan/VideoScan/MediaOps/VideoScanModel+JunkDelete.swift:561) reserves A, but never pins the B on which A’s proof depends.

   **Reproduction:** A and B match; mark B Confirmed Junk. Confirm A without an only-copy warning and freeze B’s junk confirmation. Park A after proof. Run `trashFrozenJunk(B)`: it reserves B and checks B’s identity, but never asks whether another operation relies on B. B moves; resume A; both move.

   Transcode/Reformat replacement has an additional uncovered route: [DerivativeOutputPublish.swift:210](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-aec4f835eeb481697/VideoScan/VideoScan/MediaOps/DerivativeOutputPublish.swift:210) calls Trash without any removal reservation.

   **RED recipe:** reuse `ParkingTrash` with ⌘⌫ A versus frozen-junk B, and with replacement of B. Assert original content survives outside Trash. The protocol must protect the chosen survivor through A’s move, and every removal/replacement door must honor that protection.

Original F2 and F5 are closed by inspection. F1, F3 and F4 remain incomplete against their invariants. `CatalogTrashTurnCopies` remains main-actor confined; I found no unsafe candidate-cache mutation case. The 19 mechanical test-call edits retain concrete outcome assertions.

- `RelocateSummarySheet.swift` — read, no findings within the scoped headline change.
- `CatalogKnownCopies.swift` — read, no findings.
- `CatalogContent+Table.swift` — read, no findings.
- `AdvReview20261026Tests.swift` — read, no findings.
- `AdvReview20261026TrashTests.swift` — read, no findings.
- `RelocateSummarySheetTests.swift` — read, no findings.

Reviewed `975580867`. Tracing extended to summary producers, stamp implementation and removal callers required by the brief. **No tests executed or files changed:** the session is filesystem read-only. The RED recipes above are unexecuted; supplied green counts were not independently reproduced.

## Brief

# Codex review brief — Migrate safe-words and ⌘⌫ only-copy re-check at the move (data-risk, rule 10)

**Workflow in one sentence (Rick's words):** "never lose media" — the app never tells Rick a drive can be retired unless every file on it was proven copied, and ⌘⌫ never moves the last known copy of a family video, even if another copy disappeared after he confirmed.

**This is the closing pass on YOUR cycle #150 (docs/reviews/codex/codex-review-adversarial-p2-2026-10-26.md, block/5).** Fixes: `26d7714eb` F1/F2/F5 (retire words only on a backup proven by stored whole-file SHA-256 on both sides + `describesFileNow` live stat — not a re-hash; `ContentCopyProof`; `manuallyDeletedCount` in needs-attention; Aging witnesses never prove a backup, `VolumeSafety.isSafe` itself unchanged), `103c0cffc` F3 (identity = SHA-256 only; offline copies don't count; archive copies through the same survivor rule; survivor stat re-checked off-main in `beforeRemoval` just before Trash), `975580867` F4 (process-wide `RemovalReservations`, lock-owned path set; every door through the one Trash engine plus Delete Duplicates' own worker reserves from proof through move and refuses a reserved survivor). Verify each fix closes your recipe; attack the stat-instead-of-rehash compromise (can `describesFileNow` be satisfied by changed bytes?), the archive leg's "regular file, exact size" proof, path-spelling gaps in the reservation (case-fold, firmlinks, symlinks, hard links), and any removal door that bypasses the reservation. Report new findings only if they are data-loss risks.

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
