# Codex review — September 7, 2026

Scope: bounded review of the overnight changes. Read-only production review;
headless tests only (`machine: none`). No VideoScan launch or app-hosted tests
on Rick's interactive M4. Verdicts were sent to Claude in team message #1156.

| Commit | Verdict | Evidence / remaining work |
| --- | --- | --- |
| `1701bdcf` | GO | Independently ran `bash scripts/test_nightly_failure_modes.sh`: exit 0, 39 passed, 0 failed. Crash classification precedes the existing UI-runner-hang exemption; unexplained nonzero test exit fails closed. |
| `39e21686` | GO, conservative behavior | QA traced the new scaffold-prose rejection into the composition verifier. Matching every `claim`/`claims` can reject legitimate archival prose such as “pension claim”; nonblocking fallback limitation. |
| `a880168b` | HOLD for bounded correction | New kinship dedupe drops independently requested owner/pronoun entries; see below. |
| `58a8989c` | GO on source changes; app validation pending | Four lens arguments agree with surrounding prose. Correct GEDCOM key and `#require` remove the fixture's force-unwrap trap. New card tests do not exercise the changed production routes. |

## Required correction: preserve the other requested person

`VideoScan/VideoScan/HallieTurnExecutor+SpeakerKinship.swift`, `bind`, filters
all remaining speaker pronouns and configured owner names after replacing the
relative slot. For owner Rick, `people = ["my dad", "Rick"]` and question
“videos of my dad and Rick” therefore lose Rick. The same applies to
`["my dad", "me"]`. This is a source-level finding, not an executed app repro.

Keep duplicate-relative cleanup, but preserve an independently requested
speaker. Add regressions for both conjunctions and retain the existing
`["my dad", "dad"]` dedupe case. Claude owns the correction.

## Test coverage follow-up

The new `HallieCardProseAgreementTests` manually construct a card from a lens.
Removing the four production lens arguments would not fail those tests.
Add a sensor through the actual affected trail routes rather than claiming
the helper tests close that integration boundary. No production defect found
in those four argument changes; this does not require another design round.

These verdicts do not constitute a full-main or full app-suite sign-off.

## Errands-window follow-up

- Source GO for `eb527691`: nightly reviewer explicitly selects its own model
  and endpoint. Direct CLI invocation still falls back to Hallie's setting
  with a warning; this is not full model-policy separation.
- Observed subsequent uncommitted reviewer automation edits, left untouched.
  Sent Claude #1160: minute-resolution output directories can retain stale
  verdict files across reruns; retry-only runs can compute negative quiet
  counts from the empty new-commit range. Awaiting corrective source and tests.
- Independently ran `swift test --package-path VideoScan/VideoScanCore --jobs 2
  --filter 'BirthplaceClassifierTests|LineageTrailTests'`: **24 tests passed**,
  including the 131k-person pedigree sensor (about 4.36 seconds). This tests
  geographic classification/traversal, not Hallie's natural-language routing.
- Rick clarified ancestral titles should first be ad hoc recorded-name text
  search (example: “Patrick, I Laird of Hailes Hepburn”). Existing compiled
  `sidebarRows(containing:)` supports literal substring search over preferred
  and alternate names; keep this separate from identity resolution. Sent
  reuse recommendation and test results to Claude #1161.
- Reviewer automation subsequently committed as `31ad6aea`; the two findings
  above still apply to that SHA. Shell/Python syntax checks pass; its harness
  has not been independently run because it reassigns HOME for isolation.
- In-progress kinship correction needs target-slot protection before replacement
  (reversed `["Rick", "my dad"]`) and terminal punctuation handling. Sent #1163;
  these are source-review findings, not a verdict on a finished corrective SHA.
- Batch1 `79513802` save-warning presentation has a material gap still present:
  a failed rename associates its error with the new name-derived ID, which has
  no saved card; a failed add has no card either. The warning only renders on
  a matching saved card. Sent #1164 requesting recoverable edits and error
  presentation independent of card existence, with add/rename failure tests.
