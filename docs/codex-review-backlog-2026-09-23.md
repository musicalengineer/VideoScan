# Review backlog audit — 2026-09-23

**Later disposition:** The historical review gaps below were subsequently reviewed and directly answered during Rick's requested queue drain. See [the completed drain report](codex-review-drain-2026-09-23.md) for current verdicts and remaining code defects. This file preserves the earlier audit state.

## Recent queue

Eight recent threads now have explicit direct replies. Some reviews were already delivered in consolidated messages; others required new source review and executable probes today. Acknowledgment alone is not completion.

| Claude message | Codex direct reply | Disposition |
|---|---|---|
| 1621 | 1672 | Final delete/recovery corrections source-checked at 9cf2e81e; scoped closure, no sweep approval. |
| 1635 | 1667 | Linked completed grouping/UI source review in 1644; no visual acceptance claimed. |
| 1636 | 1668 | Linked completed consolidation design review in 1643. |
| 1637 | 1669 | Linked completed S0–S2 source review in 1643. |
| 1645 | 1670 | Acknowledged corrective status and linked subsequent reviews. |
| 1652 | 1671 | Source-verified pending-alias proof and oversized/in-flight Prepare fixes. |
| 1663 | 1674 | Completed Find Similar Footage review; five findings below. |
| 1666 | 1673 | Completed S4 follow-up; two remaining P1 findings below. |

At the final check, `inbox --agent codex` was empty and `awaiting --from claude --to codex --days 2` reported every request had a reply. Neither command proves the historical backlog complete.

## Current source review

Immutable snapshot: `9cf2e81e676d28c24368bbe9b756739e0a88257f`.

### S4 — reply 1673

1. **P1: Fresh archive endpoints can contain different bytes.** `ArchiveAngelFactLenders.swift:77–79` and the archive-promotion ancestry fallback at line 108 gate on freshness but not matching current full digest and size. A source overwritten and legitimately rehashed remains connected to its former archive copy: both endpoints are fresh, their SHA-256 values differ, yet the archive link transfers a known date and contributes to same-bytes evidence. Require current identity evidence as well as freshness.
2. **P1: Repair and ordinary ancestry bypass freshness.** Repair lending at lines 81–85 and ancestry at 104–117 can lend a known date from a rewritten balanceAudio donor or parent. Transformation relationships need evidence bound to the relevant file incarnations; equal hashes are not appropriate for transformed outputs. Unsupported relationships should remain hints.

Headless probes executed production stat/fixity logic and extracted lender methods with documented stubs: **14 assertions, 10 passed, 4 failed across three scenarios**. Prior stale digest/archive-link controls now pass. Async acknowledged rollback save was source-reviewed, not exercised through the app.

### Find Similar Footage — reply 1674

1. **P1: Sampled signatures become Identical.** `FootageGrouping.swift:360–369` promotes matching segmented hashes unless whole-file digests explicitly disagree. Two actual 6 MiB files with equal sampled signatures and unequal full hashes grouped as Identical when full fixity was absent. Supplying their differing full digests prevented grouping. Identical requires complete, current content evidence.
2. **P2: An undated member bridges conflicting dates.** Per-edge checks at line 485 do not protect component merges at 578–611. Equal-duration `1990-12-25 Christmas`, undated `Christmas`, and `1994-12-25 Christmas` became one Likely group; the dated pair alone stayed separate. Preserve component-wide date constraints.
3. **P2: Scoped recomputation can publish incomplete membership.** `VideoScanModel+FindSimilarFootage.swift:155–170` expands touched memberships once. Old `{A,B}`, new `{B,C}`, scope A can update A/B while omitting C. Apply partitioning at 217–230 can also split an old group across Stop slices. Use connected closure across old and new memberships as atomic apply units.
4. **P2: A running job can restore a rejected group.** `FindSimilarFootageJob.swift:120–139` applies a snapshot without checking decision revisions. A Not same decision during a pause saves the decision but its rerun is refused while the old job remains active. Resuming can apply the rejected group without scheduling another computation. Invalidate stale results or guarantee recomputation.
5. **P2: Rejected candidates defeat the comparison bound.** `FootageGrouping.swift:478–490` counts accepted links toward the 32-partner cap. Equal-duration, same-stem records with mutually conflicting dates can require N(N−1)/2 comparisons. Bound examined candidates or partition incompatible dates; cancellation is absent inside this phase.

Findings 1–2 were reproduced headlessly with production grouping methods and relevant Core types. Findings 3–5 are source findings; no large-scale workload was executed. Wrong groups can suppress distinct recordings in Angel recommendations and One per footage. These findings do not establish deletion.

Artifacts and extraction limitations:

- `/Users/rickb/Library/Logs/VideoScan/review_backlog_20260923/output.txt`
- `/Users/rickb/Library/Logs/VideoScan/review_backlog_20260923/README.md`
- `/Users/rickb/Library/Logs/VideoScan/review_backlog_20260923/footage/output.txt`
- `/Users/rickb/Library/Logs/VideoScan/review_backlog_20260923/footage/README.md`

No app, test host, UI, real-media operation, or production edit was performed.

## Historical audit

Reviewed 35 older messages lacking direct reply links against exported Codex replies and existing review reports. Most were handled in consolidated replies, superseded, or informational. Missing reply metadata alone does not establish missing work.

Evidence of completed or superseded work:

- 1518/1520/1521: GEDCOM review in 1523–1526. Later rule-3b work in 1537/1538/1558 culminated in independently executed 16/16 at `0a69c73c`, reported in 1563.
- 1529/1531/1533/1536: recovery/replay coordination answered in 1532/1535/1543; not proof that every routing defect was fixed.
- 1577/1578/1580 and Angel part of 1587: Phase 1/2 review in 1590 and `docs/codex-review-2026-09-20.md`.
- 1599/1600/1601: duplicate/document/prune review in 1602–1604 and `docs/codex-review-followup-2026-09-20.md`.
- 1605/1612/1614: duplicate follow-ups in 1610/1611/1619 and current source closure in 1672. Prune received later review in 1642, including new D4/D5 findings; no blanket sweep approval.
- 1519/1542/1557/1560 are corrections or retractions; 1625 is a corpus handoff followed by work in 1626–1629.

**Still missing independent completion evidence:**

1. **1556/1559 — Hallie copula and routing design.** No independent verdict found for `679741da`, or answer on retrieval-only kin/media routing versus consulting both modes. 1560 retracts a transcript-regression allegation, not these requests.
2. **1564–1566 — GEDCOM identity hardening.** No explicit independent verdict found for suppression/cache bypasses, `preferredPersonID`, or Eileen's duplicate parent-family question.
3. **1591/1592 — twelve Angel corrective findings.** No finding-by-finding re-verification found for `ad074810`, including attention/audit `d0e969dd` and Clear/companions `2d83104f` + `a679cbaf`. Later narrower reviews do not close this handoff.
4. **1583/1586/1587 — fleet and CI follow-through.** Work was explicitly parked in 1588. No completion evidence found for remote script cleanup/refresh or the retained CI/nightly queue. This is a historical verification gap, not proof that machines remain stale today.

Secondary closure gaps: 1527 timestamp ordering and 1531 production test-host detection lack separately recorded verification, although surrounding work was completed.

These historical gaps remain open in this report; they were not reviewed, tested, or silently marked complete by the mailbox audit.
