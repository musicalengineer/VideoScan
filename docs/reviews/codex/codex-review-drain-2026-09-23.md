# Team-channel review drain — September 23, 2026

Rick requested completion of actionable reviews and disposition of the remaining messages. The Codex inbox had two unread messages at the start; the audit also covered 35 older messages lacking direct replies. A third new review arrived during the work. All 38 now have direct replies. Final channel checks returned no pending Codex messages and no unanswered Claude-to-Codex messages within seven days. Messages were acknowledged, not deleted; other participants' inboxes were not changed.

Review completion does not mean every reviewed change is defect-free. Remaining findings were delivered to Claude with evidence.

## Completed reviews

| Scope | Verdict | Channel replies |
|---|---|---|
| S4 lending corrections, request 1677 | 17/17 headless assertions pass at `e68fd7cef20488bd30f15cedce41c05ed6ca5b0c`; original 1673 findings closed within scope | 1703 |
| Find Similar Footage, request 1679 | 12/12 checks pass at `61d162d5795ea3708102932b312e330257f33867`; F4 lifecycle source-reviewed; one minor cancellation gap | 1717 |
| Copula and routing design, 1556/1559 | Copula correction source-approved; explicit retrieval versus cross-source factual routing recommendation supplied | 1708–1709 |
| GEDCOM identity, 1564–1566 | Three remaining consistency findings, relationship-design answer, migration recovery caveat | 1710–1712 |
| Twelve Angel corrections, 1591/1592 | Nine source-closed; three partially corrected, two residuals reproduced | 1714–1715 |
| Store isolation, 1531 | P1 Swift Testing detection gap reproduced | 1713 |
| Timestamp follow-up, 1527 | Fractional order and legacy decoding controls pass; two ordering consumers inspected | 1716 |
| Fleet/CI, 1583/1586/1587 | Stale dirty-script request resolved by current inventory; CI failure separately confirmed | 1704–1706 |

Other historical corrections, status notices, and completed reviews received direct dispositions linking the existing evidence in replies 1680–1702. Accepted-fix status 1676 was answered by 1678. This was a finite queue drain, not a background monitoring commitment.

## Remaining findings and evidence

### P1: compiled-store isolation misses Swift Testing

At `e68fd7ce`, `FamilyGraphCompiledStore.swift:230–233` checks four environment markers. The exact getter was extracted unchanged into a tiny standalone package containing one XCTest and one Swift Testing test. Running `swift test` detected XCTest but returned false in the Swift Testing helper. With no explicit root override, the production factory at 253–263 therefore selects the real compiled-store root. No actual production store was instantiated or written in this probe.

The safeguard needs coverage through actual runner entry points, including SwiftPM and Xcode. A test executed only under XCTest cannot prove Swift Testing isolation. This is a guard failure, not evidence of new corruption of Rick's tree.

Artifacts: `/Users/rickb/Library/Logs/VideoScan/review_store_detection_20260923/`. `output.txt` records one passing XCTest and one failing Swift Testing expectation. `Tests/ProbeTests/Probe.swift` contains the unchanged detection getter. `DateCodec.swift` separately executes the production date codec and locked formatter; same-second .1/.9 order and legacy whole-second decoding both passed. True timestamp ties do not acquire chronology through this fix.

### GEDCOM and Angel residuals

The [identity review](codex-review-identity-1556-1566-2026-09-23.md) documents missing live cache invalidation for identity rulings, disagreement between the returned ruled graph and unruled outcome graph, and surname/superlative/relationship suppression bypasses. It also records the people-folder migration's move-before-journal and path-only undo caveats. These are source findings, not claims that the historical migration lost files.

The [twelve-item Angel review](codex-review-angel-1591-1592-2026-09-23.md) documents three remaining P2s: inaccessible surviving companions are recorded as deleted; failed plan persistence loses unchecked-decision deduplication; Clear still performs plan reads and full-fsync saves on the main actor. The first two have bounded reproductions with explicit limits; the third is source-confirmed.

### Footage validation and minor cancellation gap

The F1–F3 production-method probes pass, including actual 6 MiB sampled-hash twins, date conflict bridging, and complete old/new membership closures. F4 revision invalidation and queued rerun were traced in source; the application job was not run.

The 100k-record Release benchmark completed in 1.432 seconds, examining 4.95 million candidates within the bound. Cancellation inside a single 20k-record name bucket was not polled until after the bucket: 0.624 seconds of additional work, with the builder's cancelled flag false. The production post-phase checkpoint still prevents application. Reported as P3 responsiveness/flag reporting; bounded inner-loop polling is recommended.

Artifacts: `/Users/rickb/Library/Logs/VideoScan/review_1679_61d162d5/{output.txt,output_scale.txt,output_cancel.txt,README.md}`. S4 evidence: `/Users/rickb/Library/Logs/VideoScan/review_1677_e68fd7ce/`.

### Fixity-stamp design feedback

Reply 1707 recommends an additive persistent volume UUID for newly hashed stamps, but rejects upgrading legacy stamps merely because today's UUID resolves and the remaining stat fields match. Legacy stamps contain no historical UUID; current lookup cannot establish the volume that supplied the old digest. Require a full rehash with before/after identity checks or independently validated historical binding. Missing UUID is not a wildcard, and a device-number fast path must not bypass a known UUID mismatch.

Apple distinguishes a [persistent, optionally unavailable volume UUID](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeuuidstringkey) from the [volume identifier that is not persistent across restarts](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeidentifierkey). The proposal is review advice, not an implemented or approved schema change. Remount, replacement, missing/duplicate volume identity, symlink races, hardlinks, restored timestamps and legacy JSON need explicit controls. Claude's reported real-catalog counts were not independently measured.

### Fleet and CI disposition

Read-only SSH inventory: M5 at `069a3b14`, clean; M1 at `2ab6f813`, only untracked `.photo-backup-2026-08-20/`. All three scripts named by the old warning were clean on both hosts, so no discard or remote checkout change was needed. Main includes the Hallie Bash correction `22a0a417`.

[CI run 35930657961](https://github.com/musicalengineer/VideoScan/actions/runs/35930657961) at `e68fd7ce` failed before tests because `GedcomFamilyGraph+CommonAncestry.swift:111` exceeded the compiler type-check budget. This remains a build defect, independently reported to Claude. A newer run was in progress at inspection; no green claim was made.

No production edits, VideoScan application/UI launches, real-media mutations, remote mutations, or broad deletion approval. Validation used bounded synthetic headless tools; the standalone SwiftPM runner probe did not load the VideoScan application.
