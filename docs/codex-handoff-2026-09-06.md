# Codex restart handoff — 2026-09-06

Historical snapshot, committed to main on September 8 for discoverability.
The branch state and open items below describe September 6, not current main.
For the subsequent work, see [September 8 morning brief](morning_brief_2026-09-08.md).

## Current assignment and working style

Rick authorized Claude to fix the weekend Hallie backlog. Codex independently reviews code, tests, robustness, testability, and realistic performance; Claude owns implementation. Coordinate through `python3 tools/team-channel.py` (see `docs/team-channel/README.md`). Read `inbox --agent codex` on return; acknowledge handled message IDs.

Rick explicitly wants less friction: accept good, tested fixes, park lower-impact residuals, and avoid repeated plan reviews or perfection loops. HOLD only for concrete material problems. Do not make Claude wait on speculative redesign. Rick plans to let Claude finish his current batch, then restart Claude too.

Settled policy: People profiles are authoritative for immediate contemporary family vitals, per field. Users maintain those values; Rick says they are corrected. Do not reopen which store wins or hardcode historical values from messages.

## Exact state at handoff

- Checkout: `fix/hallie-vitals-finish-migration`, HEAD `7dfefcd6e0dbdcc92d08f643eeaea9c901dab96e`.
- Codex review **GO** for this bounded vitals batch, sent to Claude in message **#1133**. This is a review verdict, not a merge/push operation.
- Earlier `6e01da6a` was held because ordinary `ancestorLine` still used tree dates and new life-date/place prose disagreed with evidence/source. `7dfefcd6` fixes both and adds seven route tests. No further iteration requested for this batch.
- Reviewed corrective diff and assertions. Independently reran 7 Core biography tests successfully on the final HEAD:
  `swift test --package-path VideoScan/VideoScanCore --scratch-path /private/tmp/videoscan-vitals-review-6e01da6a -c debug --jobs 2 --filter ArchivistBiographyPolicyTests`
- Claude reports 1173 app tests / 112 suites passing with one pre-existing known issue, plus 116 Core tests. App results are author-reported, not independently executed by Codex.
- Suite-selection trap: `HallieCrossWorldDadTests` lives in `HallieCrossWorldFamilyCardTests.swift`; filtering by filename silently misses it.
- No tracked modifications at handoff. Existing unrelated untracked paths: `.codex/worktrees/`, `codex-worktrees/`, `docs/mac-hw-inventory-2026-08-21.md`. Preserve them. This handoff is newly created, uncommitted.

## Next work

Claude's next batch is B5/B6/B7: kinship keywords retained after person resolution, untagged people degraded to keyword searches, and Dad/Sr/Jr identity lost by replacing a resolved identity with an ambiguous given name. He reports a dedupe commit `47dc16a0` on `fix/hallie-identity-jr-sr`; not yet reviewed. In #1133 Codex explicitly told him to implement a localized fix without another plan-review round. Review findings #1114-2/-3 are NOT Codex implementation reservations.

Ask for a bounded review packet: exact SHA, defects addressed, relevant tests/results, remaining limitations. Review actual code; distinguish source inspection, executed tests, and author/live-log reports. Keep closure tied to the reviewed SHA. No need to re-review accepted vitals changes absent new changes/evidence.

## Still-open review findings

- **#1114-1:** `HallieKinshipApposition` still uses raw tree biography/dates when a candidate has a GEDCOM ID. Explicitly NOT closed by the approved vitals batch.
- **#1114-2:** full-name forms missing from kinship overlay lookup.
- **#1114-3:** canonical-derived and alias-derived full names have equal priority, recreating Tim/Timmy ambiguity.
- **#1115:** CIA matches Ciao via arbitrary prefix matching; harmless advice comma lists are refused; some life-status and date-provenance routes remain inconsistent. Review fixes individually rather than reopening the accepted batch.
- Full weekend defect inventory is **team-channel #1120**, grouped A–F. It includes citation/evidence errors, scope/refinement/identity errors, unsupported questions answering unrelated queries, historical reasoning gaps, presentation issues, and robustness. The long message can be read from the mailbox history if needed; `inbox` shows only unacknowledged messages. Inspect the tool/schema read-only if history retrieval is needed.
- **A1 withdrawn:** lack of coverage log lines does NOT prove verifier bypass. `HallieGroundedComposer.compose` calls verification regardless of shape; coverage logging is filtered. Verifier rejects unknown plan claim IDs. A2/A3 remain reported citation symptoms: trace actual claim-to-media/link mapping, do not assume cN indexes displayed mediaEvidence. Claude was asked to own that investigation after identity.
- F4 suspected reset/log truncation is unverified and log changes require Rick escalation. E11 identification-note presentation is a product decision, not an automatic defect fix.

## Constraints

- M4 is interactive: do not launch VideoScan, host-app tests, smoke/UI tests without an explicit quiet window. App XCTest target launches VideoScan. Headless Core package tests are allowed; machine-bound UI work must explicitly route to M5/M1 or authorized M4 window.
- No merge, push, revert, app run, or tree recompile performed by Codex. Preserve existing authorization boundaries.
- GEDCOM media titles/captions-only lane was previously authorized for Codex, with images/network out of scope and Rick initiating any recompile. No implementation started; do not confuse it with current independent-review role or silently expand work.
- `.Codex/MANAGER.md` and `.Codex/agents/MANAGER.md` were absent when checked. Agent definitions exist under `.Codex/agents/`.
- All incoming messages through #1132 handled/acknowledged; inbox empty at handoff. #1133 is latest substantive outgoing verdict before restart.
