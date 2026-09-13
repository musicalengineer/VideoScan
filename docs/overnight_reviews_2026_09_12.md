# Codex review ledger — September 12 evening

Independent source reviews, without launching the app or touching live data.
Reported owner test counts are not independent test executions by this reviewer.

| Change | Reviewed revision | Verdict | Team Channel |
| --- | --- | --- | --- |
| People rename photo preservation | cb34df4b through fe297cd8 | Claude APPROVE; reports compile and 244 tests / 26 suites passing; merged with isolation sensor as 984bb560 | 1410 |
| Cached scan-target facts, follow-up | 896a72ba / 7e2d8b17 | HOLD: destructive confirmation can use stale scope | 1417 |
| Inferred-date catch-up and propagation | 3dbda42a / d3044517 | HOLD: identity and skipped-evidence corruption paths | 1413, 1415 |
| Manifest v3 and backup attestations | 7e9e2b38 / e7f4d486 | Changes requested: timestamp precision and blocking journal writes | 1414, 1416 |
| People UUID-folder migration design | 8c70b18b | Direction approved; three migration safeguards required | 1418 |
| People UUID-folder implementation | f63f141d | HOLD: migration recovery and consumer identity isolation | 1420–1423 |
| Exact delete confirmation plan, final delta | 8fddcfa6 | APPROVE source review; owner build/tests required | 1435 |
| Attestation precision/journal delta | 5c66b26b | Timestamp/journal ordering good; remaining MainActor log batch | 1429–1430 |
| Date identity/budget delta | 36b482da | HOLD: second-pass partial-hash bridge; idempotent donor-loop cost | 1433–1434 |

## Scan-target facts

Shared `TargetRemovalScope` fixes legacy prefix/origin mismatch, and mutation
funnels now cover same-count edits. However, the coalescer deliberately leaves
facts stale for at least a second. `ContentView.swift` confirms with those cached
facts and then deletes from live records and the target's current path. An append
or repoint during the window can make the confirmation understate/change the
destructive scope. Capture an exact removal plan on the gesture and validate it
through confirmation. Test the deferred-refresh window explicitly.

Performance follow-up: saves for unrelated metadata now trigger the complete
main-actor aggregate pass. Per-target removal scopes also scan all other targets,
making the worst-case projection O(records × targets²). The measured 20-target
fixture does not establish a bound for arbitrary target counts.

## Date propagation

`VideoScanModel+DateInference.swift:162` uses `duplicateGroupID` ahead of hashes.
Those groups include heuristic review candidates; even a high duplicate score
can arise from matching names/metadata with conflicting hashes. A strong OCR date
can therefore become a persistent settled date on different footage. Date
propagation needs a stricter content-identity rule than accounting groups.

The inference limit is also unsafe: Rule 1 can skip a recipient's own evidence,
but Rule 2 still considers it for propagation and checks only conflicting years.
After earlier noise consumes the limit, a recipient with DEC 25 1991 can receive
JUN 21 1991 from a sibling and never be revisited because the result is settled.
Skipped evidence must defer propagation, and bounded passes must progress.

## Backup attestations

`BackupAttestation.jsonString` serializes ISO8601 dates without fractional seconds,
but latest-wins merging compares full dates. Newer NO at t+0.9 becomes t after
round-trip and can lose to older YES at t+0.2. Preserve ordering precision and pin
the newer-NO/older-YES round trip with a regression.

`recordAttestation` also performs per-record open/write/fsync on MainActor. Slow
archive storage stalls the UI and postpones catalog notifications until the loop
finishes. Ordered journal I/O needs a background execution boundary.

Legacy CSV widths, positional reads, quoting, ordinary place restoration,
inheritance and repair undo appeared consistent in the inspected change.

## People UUID migration design

The identity/display direction is sound. Before implementation approval:

1. Back up before **any** source mutation, including assigning legacy UUIDs.
2. Persist planned old/new/UUID mappings before renames. Resume and rollback must
   reconcile interrupted moves and JSON writes, not depend on a post-rename log
   that may never have been written.
3. Quarantined or skipped profiles must not silently save into a fresh UUID folder
   or a colliding destination. Retain their actual location or refuse mutation
   with an actionable diagnostic until the conflict is resolved.

Audit name-based actions and accessibility identifiers now that duplicate legal
given names are valid; UUID ownership must survive the UI-to-operation boundary.

## People UUID implementation (`f63f141d`)

Storage review confirmed skipped legacy duplicate UUIDs can still save into a
conflicting/new UUID folder. Move mappings are written after the move, leaving a
crash window. Although migration itself now backs up before minting UUIDs,
`listAll`/`load(at:)` fallback writers bypass a failed backup. Partial rollback
discards retry information; explicit-folder loading also bypasses test-root
protection. See #1420–1421 for exact paths and correction to the design finding.

Consumer review found active Person Finder selection remains name-based:
quick-save/rejection/edit/delete operations can touch the wrong Richard. The new
`displayName` also feeds operational `ScanJob.personLabel` filtering/writeback,
so duplicate aliases collapse distinct people. Holdout queues and validation
labels remain keyed by canonical name. Legacy bundle placement returns the first
same-name profile; Identify Family ignores aliases and re-resolves name-only
promotion actions. These need UUID identity or an explicit fail-closed bridge,
with consumer tests covering actual actions on two same-name profiles.

Correct pieces: UUID card/drag/portrait/tree keys, direct delete/undo destinations,
new persisted job UUID restoration, and Hallie stable-ID/full-name/alias resolution.
No code or live data was changed by this review.

## Follow-up review checkpoints

Claude acknowledged all findings and assigned four fix branches in #1425/#1427.
One status ping was needed after an hour without a manager response; no review
silence was treated as approval. Main remained 984bb560 during these first deltas.

Delete plan: 4c85eaba closed stale cached-count scope, but needed continued target
registration checks. 8fddcfa6 added ID and exact registered-object validation
before replan/removal, with target-removed/replaced/wrong-ID sensors; approved.

Attestations: 5c66b26b normalizes timestamps consistently and orders off-main
journal batches. One synchronous `appLog.writeBatch` remained on MainActor.
Sub-millisecond timestamp ties were recorded as an advisory, not another blocker.

Dates: 36b482da fixes evidence-budget starvation and direct hash conflicts. A
second pass can still transfer A's date through unhashed B to conflicting-hash C
in one partial-hash bucket. Pin the second pass and refuse ambiguous bridges.
Already-dated recipients also need skipping before the nested donor loop to avoid
quadratic idempotent work on MainActor.

## 22:36–22:45 final-delta reviews

Delete-plan fix merged as `01d94091`. Attestation `cd801d16` APPROVED (#1439):
both console and journal batches now execute off-main in call order, including
without an archive. Conservative equal-time answer precedence is deterministic.

Date `7514bb56`: the two preceding propagation findings are fixed. New automatic
on-load cleanup remains HOLD (#1439): validating only the immediate donor keeps
downstream dates from a bad A→B→C chain; second-resolution recovery filenames can
overwrite an earlier undo sidecar. Cleanup needs provenance closure and unique,
non-overwriting recovery files. Prior tests do not exercise these sequences.

UUID `c56bd2bc`/`6628679c`: backup-failure read protection, pre-move plans, retryable
rollback, explicit-root test isolation, and save quarantine materially improve
the implementation. Remaining HOLD items (#1440–1442):

- Legacy bundle layout must not override a present conflicting UUID.
- Present-but-unresolved active UUID must not fall back to a namesake.
- Holdout/validation write entry points need ambiguity guards, including sheets
  already open when a second namesake appears; helper-only tests are insufficient.
- Legacy kinship name→UUID upgrades must refuse ambiguous names, not choose first.
- Deleting a quarantined legacy profile must not target another folder sharing
  its UUID; guard before job cancellation or storage mutation.
- Bare migration renames break internal absolute photo symlinks; rebase safely or
  quarantine these folders. Test dereferencing the photo after migration.

These are source/test inspections, not independently executed app tests. Claude
reports 693 tests / 53 suites for UUID, 154 / 18 for dates, and 23 core plus 80 app
tests for attestations. Passing counts do not cover the missing sequences above.
