# T10 reviewer record — night of September 10–11, 2026

Owner: Claude. Reviewer: Codex. Machine: M4, headless only.
Rick activated the theme at approximately 20:16 ET. Shared cap: three
heuristics or four hours, ending no later than 00:16 ET. T2 is a fallback
within that budget, not an additional overnight budget.

This is a review record, not a claim that any pending branch is merged.
Owner implementation and the consolidated outcome belong in the morning brief.

## Baseline CI/nightly status — checked approximately 20:45 ET

**Main CI was already red before T10.** At `8308fa89`,
[CI run 34540926129](https://github.com/musicalengineer/VideoScan/actions/runs/34540926129)
built successfully but failed the unit step. Python Tests and Pages passed.
The actual failed-step log includes parser timing (2.047 s versus 2 s),
transcript rendering (28 appended rows versus a ceiling of two), seven
cleanup media-matrix cases failing with ffmpeg status 187, and cleanup
sensor/vorbis-integration failures. The intentional CI canary also appears
in raw logs and must not be counted as an ordinary regression without the
summary policy. These results precede tonight's changes.

The last completed local nightly, September 10, published 7,018 passed,
one failed, 56 skipped; failure: `badgeFillsArePairwiseDistinct`. No new
full-nightly result is established by the focused Angel gate.

Reading GitHub logs initially failed because its default cache was outside
the sandbox write roots. A task-specific `XDG_CACHE_HOME` under
`/private/tmp` resolved that restriction without changing permissions.

## T10 checkpoints

### Final H1 — `bb172f6c`: merged and verified

Verified main now contains only H1 and its corrections, with
`rulesVersion = 4`; H2/H3 remain off main. Exact-head test log:
`/private/tmp/VideoScan-t10-gate-h1-bb172f6c.log`.

- **66 tests / 13 suites passed.** The removed fourteenth suite belongs
  to the held derivative heuristic, not an accidentally skipped gate.
- 100,000 notes: 0.352 s; candidate selection: 0.882 s;
  100,000-candidate sweep test: 5.776 s.
- Family-path matching advisory was also corrected to whole components
  and package suffixes, with negative substring tests.
- H2 and H3 are tracked as GH #178 and #179; the experimental combined
  branch `fix/angel-hygiene-1` is retained, unmerged.

### Revised head — `c52879e6`: H1 clear with advisories; H2/H3 held

Verified the actual gate log
`/private/tmp/VideoScan-t10-gate-c52879e6.log`: 71 tests in all 14 Angel
suites passed, including the formerly omitted promoter rule suite.
The narrower note classifier preserves bracketed human notes and has a
100,000-note scale sensor. Initial H1 blockers are resolved.

H1 code review is clear with advisories, subject to isolating its commits
from held H2/H3 and rerunning the gate on the resulting exact head. The
low-rate family demotion is an acknowledged limitation, not zero impact:
Claude reports `Part2.mp4` falls from B to C, still eligible. Family-path
markers currently use substring matching despite comments describing
components; narrowing that is advisory.

H2 is blocked: the evidence path sorts equal-score records by UUID and
keeps the first group member. It can keep a shorter/smaller copy than the
walk path. Its new evidence test uses unequal scores and misses this.

H3 is blocked: `markDerivatives` falls back to a matching basename from
any folder/group, violating the unrelated-name exclusion. Its supposed
original need only be video/not-confirmed-junk; offline, unplayable,
too-short, or suspected-junk originals can suppress a usable derivative.
The added cross-folder-positive test encodes the unsafe behavior. Repeated
same-stem folder searches can also be quadratic; the existing sweep scale
test does not exercise this new candidate-producer step.

Requested parking H2/H3 rather than another overnight redesign. Their
production call-site expansions are outside the selected allowed-file
scope; editing the scope document is not director approval. Verdict sent
as team message 1306. No timeout merges of H2/H3.

### H1 — `d122a7de`: changes requested

Reviewed the full three-file diff and the actual test log
`/private/tmp/VideoScan-t10-h1d-tests.log`.

- Verified 53 tests in nine suites passed; 100,000-candidate sweep took
  approximately 5.69 seconds (Debug ceiling: ten seconds).
- The requested promoter pure-rule suite did **not** execute. The selector
  `ArchiveAngelPromoterTests` is nonexistent; the type is
  `ArchiveAngelPromoterRuleTests`. Requested corrected run before clearance.
- The new note classifier treats every line starting with `[` as machine
  output. A human note such as `[1984] Dad and Donna at Thanksgiving` loses
  its human override. Requested narrower machine signatures and regressions.
- Requested explicit accounting for old low-rate H.264/HEVC family files:
  grade-C demotion still permits later selection, but does lower priority.
  Preservation-codec controls alone do not demonstrate zero family impact.
- The reported before/after profile is a Python projection over saved
  evidence, not a completed production reassessment. The reported RED was
  inferred against the old implementation, not an executed failing test.

### Integration scope warning — H2/H3

`ArchiveAngelJob.selectFromEvidence` calls `hardFloor`, not `select`.
The sweep calls `verdict` per record, not `select`. Thus batch duplicate
and related-original rules implemented only in `select` do not fix fresh
cached-evidence batches, even after a rules-version bump. These consumers
are outside T10's allowed files; requested parking or explicit scope
resolution rather than claiming scorer-only tests establish production parity.

## Secondary gallery review — `4a82887f`: hold merge

Read-only review; no independent test run or app launch.

- `FamilyAssetStore.personFolders` adds the legacy resolved folder before
  applying stricter read-side identity exclusions. A sole matching-name
  folder with another GEDCOM pointer or conflicting birth year can supply
  documents for the wrong person. Require composed-store regression tests.
- `readFolderNames` turns an unsafe nonempty GEDCOM ID into an empty ID and
  permits name fallback, weakening the prior fail-closed behavior.
- Advisories: uncapped document galleries can invalidate their own web links
  when the token map clears at 256; serve-time checks reject leaf symlinks
  but not replaced ancestor-directory symlinks.
- Stable-ID gallery continuation and the explicitly disclosed 24-photo
  presentation cap produced no blocking finding in the inspected paths.

## Separate owner work — GH #175 archive-column sorting

Claude identified this as a separate Rick request, not a T10 expansion.
Read-only review of `cd6bb5ea` found the new per-render date-key extraction
would parse legacy Promote notes and allocate formatters for every row;
the tuple-only scale test omitted that production cost.

Revised `3b94c35e` caches dates in the existing revision-keyed category
snapshot, used by both sorting and cells. **Code review clear with
advisories**; verified its log shows 16 tests / three suites passing.
The new 100,000-record/5,000-legacy-copy test exercises the real resolver
and repeated unchanged memo reads. Pure sort sensor: 0.203 s.
Follow-up: mutation/revision invalidation test and an eventual UI click
smoke; existing per-render sorting remains separate technical debt.
No UI was launched by this reviewer.

## Coordination

Findings delivered through team-channel messages 1297, 1298, 1300, 1301,
and 1303. Reviewer silence is never approval; owner overrides must remain
explicitly attributed as unreviewed owner decisions.

## Close — approximately 22:05 ET

Claude closed implementation at 21:55; Codex verified the final artifacts
and corrected the consolidated brief's projection/cohort wording. Work
ended early within the four-hour cap; no ongoing reviewer loop is claimed
after this handoff.

- H1 is merged at `bb172f6c`; separate archive-sort fix at `3b94c35e`;
  three advisory Hallie questions at `12fdc2fb`.
- Verified strict replay summary and flagged answers: **18/20 clean**,
  20 completed in 55 s, no timeout/missing turns. Actual remaining flags:
  `strict-011` answers “dad” with medieval Dafydd; `strict-004` uses
  “passed away.” The strict corpus hash matches the recorded artifact.
- This is the strict suite, not a replay of the three newly harvested
  advisory cases. Binary: `bb172f6c`; requested model: `qwen3.8:27b-mlx`;
  reachable local endpoint: `127.0.0.1`. Host diagnosis tracked in #181;
  bare-kin identity defect tracked in #180.
- The current replay's tree-backed answers establish family-data access.
  Do not conflate its host problem with the earlier independently observed
  missing-GEDCOM run or claim full fleet parity.
- The top-50 projection is preliminary: its replacement list includes
  unknown-codec `Silence.m4v`, so it is not 21 verified family originals.
  Final production re-profile remains pending the next assessment.
- Baseline CI remains red; the new full CI run was still in progress at
  reviewer close. No full-suite-green claim is made.

Final handoff: [morning brief](morning_brief_2026-09-11.md).
