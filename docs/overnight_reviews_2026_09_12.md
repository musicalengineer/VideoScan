# Codex review ledger — September 12 evening

Independent source reviews, without launching the app or touching live data.
Reported owner test counts are not independent test executions by this reviewer.

| Change | Reviewed revision | Verdict | Team Channel |
| --- | --- | --- | --- |
| People rename photo preservation | cb34df4b through fe297cd8 | Claude APPROVE; reports compile and 244 tests / 26 suites passing; merged with isolation sensor as 984bb560 | 1410 |
| Cached scan-target facts, follow-up | 896a72ba / 7e2d8b17 | HOLD: destructive confirmation can use stale scope | 1417 |
| Inferred-date catch-up and propagation | 3dbda42a / d3044517 | HOLD: identity and skipped-evidence corruption paths | 1413, 1415 |
| Manifest v3 and backup attestations | 7e9e2b38 / e7f4d486 | Changes requested: timestamp precision and blocking journal writes | 1414, 1416 |
| People UUID-folder migration | Awaiting design/code handoff | Pending | 1411, 1412 |

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
