# Archive Angel coverage — preliminary adversarial review

Reviewed 2026-09-26 for Rick. Snapshot: `main` and `feat/angel-coverage` both
resolved to `e6e86ab3bd720c787e8b703a77527634fb965d5b`; no committed feature diff.
The sibling worktree `/Users/rickb/dev/VideoScan-wt-angel-coverage` exists but
its contents are sandbox-blocked. This is a head start on the design and
existing integration boundaries, **not approval of the feature implementation**.

Sources: `docs/footage_groups_gap_plan_2026-09-26.md`,
`docs/footage_tech_survey_2026-09-26.md`, `docs/find_original_design.md`,
`docs/archive_angel_wise_design.md`, and relevant production/test code.
Two read-only QA agents and a testing agent reviewed separate concerns;
the manager checked the cited source paths. Findings below are source-confirmed,
not runtime reproductions. No app, app test host, media analysis, or tests ran.
No production code changed. Technology-survey performance/vendor claims were
not independently benchmarked or fact-checked in this pass.

## Existing code defects the feature must account for

### C1 — P1: Fallback Prepare forgets that footage is already archived

**Location:** `VideoScan/VideoScan/ArchiveAngel/Prepare/ArchiveAngelJob.swift:402`.

The sweep calls `markArchivedFootage` in
`Facade/VideoScanModel+ArchiveAngelSweep.swift:26`. The fallback Prepare walk
only runs derivative marking and family attention. Individual projection leaves
`archivedFootageOriginal` false; the ordinary archived predicate does not inspect
footage membership. Thus evidence freshness changes the archive exclusion.

**Counterexample:** A is archived. Differently named B is a rank-1 Likely member
of A's footage group, with no byte-duplicate or `derivedFrom` link. B is a dated,
starred 30-minute video. The sweep rejects B; absent/stale/insufficient evidence
causes Prepare to walk the catalog and B can be selected.

**Fix direction / acceptance:** Share the whole-set eligibility facts between
sweep and fallback. Compare the selected material with fresh, absent, stale,
and insufficient evidence; already-covered footage must stay excluded. New
coverage pre-passes need the same parity.

### C2 — P1: A second batch can select another copy of material already prepared

**Location:** `VideoScan/VideoScan/ArchiveAngel/Prepare/ArchiveAngelJob.swift:417`.

Fallback removes exact in-flight record IDs before copy selection. If A is
prepared, sibling B survives and can become the recording's representative.
The cached path deliberately rejects the entire component when any member is
in flight (`ArchiveAngelJob+Evidence.swift:270`).

**Counterexample:** A and B share a duplicate group or Likely footage group;
neither is explicitly marked Extra Copy. Prepare A, leave the batch open,
invalidate evidence, then ask for another batch. B can be selected.

**Fix direction / acceptance:** Exclude recording components containing an
in-flight member, using consistent grouping in both paths. Test two successive
batches with and without cached evidence and after regrouping.

### C3 — P1: A human “Not the same” can still become “Another copy”

**Location:** `VideoScan/VideoScan/ArchiveAngel/Recommend/ArchiveAngelRecommendations.swift:389`.

The enabled `nameAndDuration` fallback builds a global key from lowercased
filename and duration rounded to one second. It has no date/folder identity or
human cannot-link constraint. Candidate inputs do not carry `footageDecisions`.
After Find Similar Footage correctly keeps two records separate, the classifier
can reunite them and label one `.anotherCopy` (`:558`–`:584`).

**Counterexample:** `/1990/IMG_0001.mov` and `/1994/IMG_0001.mov`, each 600 seconds,
are unrelated recordings explicitly marked Not the same, with no duplicate
group. One disappears from the recommended classes with a copy explanation.

**Fix direction / acceptance:** Honor negative identity decisions at every
identity-collapse boundary; weak filename/duration evidence must not silently
overrule them. Test through AA classification after the grouping job, not just
the grouping core. This finding concerns classification/recommendation lists;
it does not establish permanent archived suppression or universal batch collapse.

### C4 — P1: Archived-footage suppression overrides the repair exemption

**Location:** `VideoScan/VideoScan/ArchiveAngel/Recommend/ArchiveAngelScorer+Sets.swift:25`.

`CatalogContent+Promote.swift:130` deliberately exempts `rebuildAudio` and
`externalRepair` from inheriting their source's archived status. But footage
grouping accepts every `derivedFrom` edge (`FootageGrouping.swift:490`), and
`markArchivedFootage` marks all rank>0 members of an archived-original group.
The `archivedCopy` floor then rejects the repair
(`ArchiveAngelScorer+Rules.swift:105`).

**Counterexample:** An archived DV source has damaged audio. Its repair retains
camera metadata but takes the derivation originality penalty, so the source is
rank 0 and repair rank>0. While both records remain active, the repair is hidden
as already covered even though the explicit archived predicate says otherwise.

**Fix direction / acceptance:** Preserve the repair exemption through footage
suppression. Test both repair kinds with an archived damaged parent and an
unarchived repaired output; include the state before the old source is superseded.

## Proposed-design flaws and unresolved contracts

### D1 — P1: Fingerprint edges erase the distinction between overlap and identity

**Location:** `docs/footage_groups_gap_plan_2026-09-26.md:48`–`:51`.

The proposed UUID-pair edge makes audio/visual fingerprints Likely and passes
them into ordinary union-find. It carries neither typed containment nor machine-
readable ranges/coverage. This contradicts `find_original_design.md:29`–`:31`,
which requires ranged relationships and explicitly says shared audio is not
identity. A free-text detail does not let a consumer enforce these distinctions.

**Counterexamples:** Two cameras share room audio; unrelated edits reuse a
soundtrack; compilation C contains distinct recordings A and B. Partial A–C and
B–C matches must not make A and B equivalent. Otherwise archiving whichever
member ranks first can suppress footage absent from that archived member.

**Required contract:** Only sufficiently supported whole-recording equivalence
may enter the collapse graph. Keep shared audio, partial containment, and event
similarity separately typed; carry ranges and evidence identity/version before
consumers rely on them. Test same-sound/different-picture negatives, reused music,
and compilations with disjoint source segments. An empty default provider is
safe today, but the proposed seam's semantics are unsafe for its intended use.

### D2 — P2: Date plus folder cannot reliably identify an event

**Location:** `docs/footage_groups_gap_plan_2026-09-26.md:34`–`:36`.

The motivating case is differently named Thanksgiving edits in different folders.
If those folder basenames differ (`Exports`, `Tape12`, `Restored`), the proposed
date+folder key still produces different events. Conversely, unrelated files
dated only `1994` under a generic `DCIM`/`Imports` folder collide. Date precision
and confidence must survive the projection; a year is not a day.

**Required contract:** Treat this key as a limited diversity heuristic with
honest explanations, or define corroborating event evidence. It must never mean
duplicate identity or already archived. Test both false splits and false merges,
unknown dates, month/year precision, and conflicting conversion/capture dates.

### D3 — P2: Raw file backlog rewards duplicate-heavy years

**Location:** `docs/footage_groups_gap_plan_2026-09-26.md:37`.

The proposed `[year: (unarchived, archived)]` file counts are not unique footage
coverage. Importing 1,000 copies of one 1994 recording can increase that year's
bonus without adding a single new moment. Archived redundant copies can skew
the denominator in the other direction. Junk and working copies also need an
explicit eligibility rule before they influence the backlog.

**Required contract:** Compute coverage from actionable unique material, with
documented confidence handling. Adding copies must not change the unique picks
or coverage reward. Unknown dates need their own explicit treatment.

## Acceptance gates for the eventual implementation

- **Cache/fallback parity and invalidation:** Coverage depends on the catalog,
  not just a candidate. Change archive coverage, undo a promotion, or regroup
  footage without changing policy; cached selection must match a fresh sweep or
  explicitly decline the cache. Current cache guards check freshness/attention
  (`ArchiveAngelJob+Evidence.swift:64`) and reuse stored scores (`:179`).
- **Coverage beyond the score cutoff:** Put the top 500 candidates in 1994 and
  lower candidates in four other years. A ten-item cap-two batch should find
  ten diverse picks. Test cached and fallback selection, shuffled IDs, and fresh
  slot replacement. The existing arrival-band/200-extra-look cutoff (`:112`)
  plus post-filter/full-batch requirement (`:200`) makes a pre-pass-only scale
  test insufficient. Measure end-to-end 100k selection and projections.
- **Scarce-year behavior:** With only one eligible year, a strict cap of two
  cannot fill ten slots. Pin either a clearly reported partial batch or explicit
  soft-cap relaxation. The proposed “never exceeds cap” sensor forbids the latter.
- **Duration policy:** The proposed >2-hour penalty changes an existing contract:
  `ArchiveAngelScorerTests.swift:220` explicitly gives three-hour captures +60
  with “no ceiling — a two-tape capture is still the whole thing.” Under two
  minutes is currently a hard automatic floor, not a score penalty; explicit
  selection has a separate 60-second floor. Resolve the desired behavior rather
  than weakening assertions to fit an implementation. Pin 60/120/300/7200-second
  boundaries, long complete captures, and missing/non-finite duration handling.
  Shortness is a prioritization policy, not proof that a family moment is worthless.
- **Coverage disabled:** Preserve final IDs, ordering, scores, explanations,
  rejection/overflow counts, and cache/fallback behavior, not merely RankKey
  comparator parity. The existing `ArchiveAngelA4DeterminismTests.swift:59`
  fixture puts all 100k candidates in one year yet expects 25 picks (`:83`);
  retain it explicitly with coverage off and add a separate coverage-on fixture.
- **Content analysis scope:** The gap plan supplies metadata diversity and a
  fingerprint seam, not an implemented audio/visual content engine. Validate
  content usefulness and false suppression on labelled material before treating
  the technology survey as evidence of recommendation quality. Include camera
  originals, trims, repairs, compilations, repeated music, quiet/silent footage,
  and same-event/different-camera negatives across the project's media matrix.

Final implementation review remains pending a readable feature diff. It should
trace recommendation → Prepare → Review with the same material identity and
coverage rules, and verify the above cases before merge approval.
