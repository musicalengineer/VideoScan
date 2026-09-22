# Claude code review — September 20, 2026

Reviewed immutable snapshot **2139c138**, including attention memory
`f36da7a6`, follow-up fixes `f780df31`, People audit `a4ffa4e4`, waiting-row Skip
`9a60f58f`, buffer hygiene `606aecbd` / `ce236216`, and isolation `2139c138`.

**Disposition: changes required.** Source review by two QA agents, a test
coverage reviewer, and Codex Manager. `machine: none`; no app launches, builds,
or test execution in this review. Commit-message pass counts are author-reported
and are not independent execution evidence. Line references below are for the
reviewed commit, not subsequent edits. App paths are under `VideoScan/VideoScan/`.

## Fix before clearing the review

1. **Clear must refuse an unreadable current plan.**
   `VideoScanModel+ArchiveAngelBufferHygiene.swift:115` uses `try? load ?? snapshot`.
   Display a ready batch, then corrupt/make its current plan unreadable before
   confirming Clear: the stale snapshot authorizes attention writes and deletion.
   This contradicts the unreadable-batch preservation policy in
   `ArchiveAngelPlan.swift:477–482`. Require a successful current-state read.
   Regression: corrupt/missing plan after display; no deletion or ledger change.

2. **Clear ignores failed persistence.**
   `VideoScanModel+ArchiveAngelBufferHygiene.swift:129–149` appends attention,
   ignores `saveLogged` failure, retires companions, and schedules removal.
   With save and removal failures together, the on-disk plan stays ready and a
   retry records another half-skip. Make failure explicit and ensure retries do
   not duplicate the decision. Current tests inject removal failure only after
   successful save; add the failed-save and retry paths.

3. **Symlink aliases bypass active-batch protection.**
   `ArchiveAngelPlan.swift:556` guards lexical paths; Clear derives its allowed
   root from the candidate's parent (`...BufferHygiene.swift:100–104`). Normal
   callers scan the configured buffer and loading replaces embedded `batchDir`,
   so an arbitrary JSON path alone is not the failure. The concrete path is a
   scanned `batch-alias` symlink to a live batch: a different liveness key allows
   Clear to save discarded state through the alias into the live plan. An alias
   to an external batch similarly permits external mutation. Validate canonical
   identity and trusted ownership before any plan read/write/claim. Test aliases
   to active and external sentinel batches through the real Clear entrypoint.

4. **Failed file removal is reported as permanent deletion.**
   `ArchiveAngelJob.swift:240,509–510,788–803` and
   `VideoScanModel+ArchiveAngelCompanions.swift:39–52,82–84` retire catalog records
   and append `copyDeleted` before confirming deletion, or after swallowed
   removal failures. On a read-only/unwritable folder, surviving companions vanish
   from active catalog results and receive an incorrect history. Reconcile
   confirmed removals; preserve surviving records. Test real Skip/Cancel/settle
   orchestration with a completed companion and an injected removal failure.

## Attention correctness

5. **Sweep completion time can certify stale attention.**
   `ArchiveAngelSweep.swift:267,344–347` snapshots attention before scoring but
   stamps evidence when scoring finishes. A skip during scoring is older than
   the resulting timestamp, defeating `ArchiveAngelJob+Evidence.swift:47`.
   Track the captured attention revision and reject stale publication/use.
   Regression: suspend scoring, record attention, resume, then select a batch.

6. **Cached selection loses family freshness.**
   `ArchiveAngelJob+Evidence.swift:77–84,93` projects candidates without the
   family-attention pass, leaving `familySkips` at zero. A never-proposed variant
   of skipped footage can receive "New to you" and displace genuinely fresh
   footage. Fresh candidates are also counted before family deduplication.
   Require cached/full-walk equivalence with sibling variants and family fatigue.

7. **Promote retries count an unchanged unchecked row repeatedly.**
   `ArchiveAngelReviewSheet.swift:468–473` emits skipped attention on each click.
   Leave B unchecked and retry failed promotion of A three times: B can receive
   three skips and a 90-day rest from one decision. Persist an idempotent
   batch/record decision; test failed promotion and repeated attempts.

8. **Startup loading can replace newly recorded attention.**
   `ArchiveAngelAttention.swift:212–220,234–236` replaces the store after an async
   ledger read. Events recorded after that read's snapshot can be discarded by
   replacement, including moving `lastEventAt` backward. Preserve intervening
   events or gate dependent actions. Test with a suspended startup read.

## UI, scale, and audit

9. **Removal completion leaves stale hygiene UI.**
   `ArchiveAngelBufferHygieneCard.swift:174–178` refreshes immediately and drops
   completion tasks. The detached completion only logs. A slow removal can let
   the refresh cache a live/discarded row; after removal succeeds or fails, that
   row remains busy and retry-disabled until another refresh. Refresh on
   completion and protect against older scans republishing stale state.

10. **Clear still blocks the main actor.**
    `...BufferHygiene.swift:124` walks the folder when callers omit bytes (the
    review sheet does); synchronous plan read/save also remains. Clear all scans
    the entire catalog once per batch through `...Companions.swift:39`.
    The existing 200-plan test injects sizes and misses this work. Add a real
    entrypoint 100k-record/multiple-batch budget and a responsiveness sensor.

11. **Waiting-row Skip disappears when the job stops.**
    `ArchiveAngelDetailView.swift:39,47–49` still gates the button on an active
    job. If all rows fail the space precheck, the job quickly finishes and Skip
    disappears. Test the completed batch with waiting rows, not only
    `plan.skipEntry` while constructing a preparing plan.

12. **Audit equality loses same-size changes.**
    `POIProfileAudit.swift:82–84` compares kinship counts and note lengths rather
    than original values. A changed relationship at equal count, or notes
    `AB` → `CD`, can produce "no identity field changed." Compare original
    values before redacting display text. Add same-count/same-length regressions.
    Separately, independent detached journal appends at line 123 can reorder
    rapid edits; second-resolution JSON dates cannot recover their order.
    Serialize submission order and test `record()`, not only direct `append()`.

## Test integrity and resolved items

- The strengthened Angel testbed still does not prove a successful terminal
  job state or required output set. `ArchiveAngelTestbed.swift:186–226` permits
  a done step with no output path, skipped access output, or empty existing file;
  final plan-save failure can leave successful rows despite failed job state.
  Require expected step completion, nonempty regular outputs and terminal
  success. Reject mixed valid/invalid duration lists instead of dropping bad
  tokens with `compactMap`.
- Propose/skip attention and skip/cancel/settle companion tests mostly exercise
  helpers, not real lifecycle entrypoints. Add these integrations so removing
  the production wiring cannot leave the tests green.
- Isolation exclusions still watch actual catalog, ledger, Angel, POI and audit
  state; this is not a broad removal of isolation checking. Match exact path
  components instead of `hasPrefix("team-channel")`, and add positive controls
  for product-file creation/change/deletion. Also directly pin the evidence
  store's default test-host directory; explicit-directory tests bypass it.
- **Resolved:** Release test-hook availability; final successful summary saved
  in the plan; single-line note substring suppression. Normal successful
  companion deletion now has reconciliation; failure behavior remains open.
- Existing attention tests have meaningful 100k-record coverage. Pure curation
  rules do not need media decoding; cleanup orchestration still needs real
  lifecycle and failure coverage.

No implementation changes were made by this review. Findings are sent to Claude
for correction and explicit disposition, followed by review of the exact fix
commits. CI/fleet maintenance is secondary to this queue per Rick's instruction.
