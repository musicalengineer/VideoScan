# Codex review — Cutover B2.2 synchronous commit

- Range: `d2b8a5bef..f3900b36f`
- Credits spent: unavailable (metering not exposed)
- Tokens: 74462
- Finding count: 2
- Verdict: block** — at `1c25144e4`, rescan purge remains open and one new P1 can make accepted edits permanently unsavable.
- Run: 2026-10-18T03:27:41Z (cycle #102, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (metering not exposed) | Finding count: 2

Verdict: **block** — at `1c25144e4`, rescan purge remains open and one new P1 can make accepted edits permanently unsavable.

B2.1 findings:

- **(a) Propagation — CLOSED.** [CatalogCommitter.swift:302](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:302) runs detection → write → absorption → propagation without suspension. [CatalogCommitBaseline.swift:236](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogCommitBaseline.swift:236) propagates the final write per content/group. The original concurrent-edit reproduction is eliminated.
- **(b) Marker flight — CLOSED.** The same synchronous pipeline eliminates mutation during a first insert or pending-row promotion.
- **(c) Pending held — CLOSED.** [CatalogCommitBaseline.swift:106](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogCommitBaseline.swift:106) requires the waiting fingerprint to match the durable payload’s fingerprint; failed updates cannot inherit durability from an older payload.
- **(d) Marker replay — CLOSED.** [CatalogCommitter.swift:172](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:172) commits the current snapshot before the next marker mutation. The historical replay mechanism is gone; the original A→B→Trash→A→Undo reproduction now preserves A when writes succeed.
- **(e) Rescan purge — OPEN.** [CatalogCommitBaseline.swift:96](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogCommitBaseline.swift:96) treats two observations of absence as deletion; synchronous saves require only one. Given the brief’s long-scan absence across two commits, the live file’s old ID is purged. Held payload bytes now survive, but [GRDBCatalogRepository+LivePending.swift:29](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+LivePending.swift:29) excludes them from reload. Reintroducing the file under a new ID does not reconnect that old payload, so previously saved curated values remain hidden. Same-ID recommit can recover it; forensic retention alone does not close this finding. The scoped test explicitly expects exclusion after two absences; it does not establish scan completion.

**New P1 — failed marker pre-commit does not veto the accepted mutation.** [CatalogCommitter.swift:174](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:174) ignores `commitNow`’s failure. [VideoScanModel+RemovalMarker.swift:91](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/MediaOps/VideoScanModel+RemovalMarker.swift:91) still applies Undo, increments the revision, and returns success.

**Failure scenario:** stored revision 0 → hold/read-only → Trash revision 1 → Undo revision 2 → release/reopen; revision 1 was never stored or retained, so [CatalogCommitBody.swift:225](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitBody.swift:225) rejects revision 2 and every subsequent whole-row save, including new notes or stars. Refusal messages do not recover the missing revision.

**Deadlock:** no wait cycle found in the scoped implementation. [GRDBCatalogRepository.swift:473](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:473) releases the gate lock before entering the writer queue; the async writer’s transaction needs no main-actor continuation. Import holds refuse commits rather than synchronously waiting. External reader/import/quit caller behavior cannot be certified outside this scope.

**Migration:** read, no findings. Open runs the migrator; v5 follows v4 and adds the table/index transactionally. Migration tracking makes reopening idempotent. No dedicated v4→v5/reopen execution was performed.

**The durability guarantee is refuted.** Failed marker pre-commits can leave accepted edits volatile indefinitely, beyond the two-second debounce; false purges can hide already-durable edits without either stated exception.

Other scoped files/tests: **read, no additional findings**. Tests inspected, not executed under the no-files constraint. No files written.

## Brief

# Codex brief: cutover B2.2 — synchronous main-actor commit (2026-10-18 night; data-risk)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~700 words.

**Your B2.1 pass:** `docs/reviews/codex/codex-review-cutover-b2-1-closing-pass-2026-10-17.md` (block: propagation, marker flight, pending held, marker replay, rescan purge). **The re-scope:** the commit is now synchronous on the main actor — snapshot → detect → plan → `writeBlocking` → absorb → propagate in one turn; the off-main flight is deleted. Range: `d2b8a5bef..HEAD` on main (merge of `2ea1efb94`). Files under `VideoScan/`: app `VideoScan/Catalog/CatalogCommitter.swift`, `Catalog/CatalogCommitBaseline.swift`, `Catalog/CatalogMarkerRelay.swift`, `MediaOps/VideoScanModel+RemovalMarker.swift`; Core `VideoScanCore/Sources/VideoScanCore/Commit/*`, `Store/GRDBCatalogRepository.swift` (`writeBlocking`), `Store/GRDBCatalogRepository+Load.swift`, `Store/GRDBCatalogRepository+LivePending.swift`, `Store/CatalogCommitB22Schema.swift` (v5: pending_purges + import_items.landed_ref index); tests `VideoScanTests/CatalogCutoverB22Tests.swift`, `VideoScanTests/CatalogCommitterSyncSensorTests` (in that file or near), Core `Tests/VideoScanCoreTests/Store/CatalogReadBackPlanTests.swift`.

**Do only this:** (1) each of your B2.1 findings (a) propagation, (b) marker flight, (c) pending held, (d) marker replay, (e) rescan purge: CLOSED (file:line) or OPEN (why). (2) at most THREE new P1 findings with file:line + one-line failure scenario — focus: can `writeBlocking` deadlock (called on the main actor while a GRDB reader or the async `write` path also needs the writer; the import job's hold; quit); the `markerWillChange` pre-commit when the store is read-only or held (agent says it refuses with words — is any accepted edit lost?); the two-look purge (an id absent at two consecutive full commits because a long scan swaps records twice — is a live file's row purged and its curated values lost?); schema v5 on an existing v4 catalog (migration on open, idempotent?). Confirm or refute: after the flip, an edit accepted by the app is never lost except by a crash inside the 2 s debounce or an explicit 'Quit and lose N'.
**Do not explore outside the files listed above and their tests.**

## Closed

Closed by `49cb7794a` at 2026-10-18T05:48:45Z. closed by the next batch; chain ended at B2.7
