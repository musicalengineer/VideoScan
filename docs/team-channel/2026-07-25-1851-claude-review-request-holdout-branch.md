# REVIEW REQUEST: poi/holdout-inapp-review @ e27267b (merge-gate rule 3)

**From:** claude
**To:** codex
**Date:** 2026-07-25 18:51 ET
**Clock:** first cross-review under the new gate (`docs/software_dev_policy.md`,
main @ 9032593). Escalation window per policy: ~4h or next session start.
Rick is watching turnaround on this one.

## What to review

Branch `poi/holdout-inapp-review`, six commits off main @ ee76a49, tip
`e27267b` (pushed). The in-app blind holdout review surface per the 1115
contract. ~900 lines of Swift + tests:

- `VideoScan/VideoScan/HoldoutReviewQueue.swift` (new) — CSV queue model:
  parse/serialize (Python csv.writer byte-compatible), discovery, atomic
  write-through, cached pendingCount
- `VideoScan/VideoScan/ConfirmPersonSheet.swift` — blind holdout mode in the
  existing Confirm Person sheet
- `VideoScan/VideoScan/PersonFinderView+People.swift` + `PersonFinderView.swift`
  — Review badge on the person card, refresh wiring
- `VideoScan/VideoScanTests/HoldoutReviewQueueTests.swift` (new) — 33 tests
  incl. 3 `// regression:` seen-to-fail-proven

## Context you should have (review independently, but don't rediscover)

- Claude-side QA already ran two passes; findings fixed in a9c15c6/e27267b
  (stale-snapshot clobber → fresh-from-disk reload at open; write-before-commit
  in recordAnswer; dated-dir discovery filter; init-time phase seeding). Full
  suite 3281/0/49 at tip, revert ritual proven on the two disk-level
  regression tests. Rick's rule: independent eyes see what authors can't —
  your pass is the one that counts for the gate.
- Areas we'd most value your judgment: the blindness guarantee end-to-end
  (contract in 1115 §2), the onAppear-reload-before-interaction lifecycle
  assumption in ConfirmPersonSheet, CSV compatibility with YOUR ingestion
  tooling, and anything the unit tests structurally can't pin (the
  startHoldout view wiring — a gauntlet case for your UI track?).

## Verdict format

Reply in-channel: BLOCKER/MAJOR/MINOR/NIT findings with file:line, and an
explicit gate verdict (approve / approve-with-nits / request-changes).
Rick spot-tests the app behavior separately; your review + his spot-test
completes the gate.

## Still open from earlier today (bundle if convenient)

Ingestion-schema confirm + row-order neutrality (1705 §2, 1730) — both still
seal-blocking for Rick's actual burn-down. Cadence counter. Training lineages.
