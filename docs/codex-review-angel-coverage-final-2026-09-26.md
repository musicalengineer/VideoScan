Credits spent: unavailable (not exposed by this session) | Finding count: 4 | Closed: 4 (feat/angel-coverage, 2026-09-26 — this copy of the review lives in the feature worktree; main's copy is untouched)

# Review #1731 — Archive Angel coverage, rules v13

**Verdict: merge-after-fixes.** Reviewed exact range
`e6e86ab3bd720c787e8b703a77527634fb965d5b..8a86a2ebb4ed4a929571e21f535dcb98bfe613e5`.
All source locations below refer to the reviewed head, not the current main
checkout. Both objects were already available locally; no sibling-worktree
access or fetch was necessary. Review stayed within the requested production,
test, and policy-document scope.

## F1 — P1: Coverage removes a fresh candidate after it satisfied the cache cutoff

**Location:** `VideoScan/VideoScan/ArchiveAngel/Prepare/ArchiveAngelJob+Evidence.swift:213`
(fresh counter), `:139` (stop decision), `:241`–`:246` (post-filter acceptance).

**Reproduced in a standalone exact-method harness.** `freshCollected` accounts
for duplicate groups and families, but not the new day/year filters. A fresh
candidate subsequently held by coverage still satisfies `freshWanted`. The
coverage arm can fill the requested count with older candidates, stop scanning,
and return a nonnil cached selection despite an eligible fresh replacement
farther down the list. The full selection applies fresh slots to the complete
coverage-filtered list and chooses differently.

Counterexample: count 2, year cap 1, fresh share 0.5; all Ready, distinct
families, no copy groups, fresh/current evidence:

| Candidate | Year | Score | Previously proposed? |
|---|---:|---:|---|
| A | 1994 | 100 | Yes |
| B | 1994 | 99 | No |
| C | 2010 | 98 | Yes |
| D | 2020 | 97 | No |

Actual harness result:

```text
CACHE ["A-old-1994", "C-old-2010"] projections 3
WALK ["A-old-1994", "D-fresh-2020"]
```

B satisfies the fresh counter, but the cap keeps A instead. Once C fills the
coverage count, D is never projected. The cache accepts two old picks.

**Required behavior:** Count fresh candidates that survive the applicable
selection constraints, continue searching, or decline the cache. Do not accept
a full but different batch merely because its row count is correct.

**Pinning test:** The four-row fixture above must return the same IDs and
freshness explanation as full selection, or nil. Repeat using a same-day
collision, mixed attention histories, the default fresh share, and shuffled IDs.
The current cutoff fixtures mostly use fresh candidates and miss this interaction.

**Closed by 32ff92a3** — test `ArchiveAngelCoverageCutoffTests.freshRowHeldByCoverageDoesNotSatisfyTheFreshArm` (the four-row fixture: same year / same day / mixed attention / default share, 16 id draws each; RED 128 issues before). Fix: `CoverageArm.noteCollected` reports whether a collected row survives the day/year rules and only survivors count toward the fresh share; the fresh arm skips rows of a year at its share by the evidence year (`freshArmWants`); `freshShareShort` declines a cache that stopped early with fewer fresh picks than it counted.

## F2 — P1: Copy multiplicity can move an existing recording between year buckets

**Location:** `VideoScan/VideoScan/ArchiveAngel/Recommend/ArchiveAngelEvent.swift:151`
and `:167`.

**Source-confirmed.** Components are counted once, but their year is selected
by majority vote over physical files. Importing another copy can change a
recording's year and other candidates' bonuses without adding any new footage.
Repeated conversion dates can outvote Rick's annotation.

Counterexample: nine independent unarchived 1994 recordings, plus one duplicate
group containing A with Rick's date `1994` and B with no user date and an
encoder-only 2026 container stamp. Initially the 1:1 vote chooses 1994 by the
earliest-year tie break. The 1994 bucket has ten recordings, meeting the default
bonus threshold. Import one additional copy of B with the same weak date facts:
the 1:2 vote moves the existing recording to 2026, leaving only nine in 1994.
All 1994 candidates lose their backlog bonus.

**Required behavior:** Resolve a recording's date using evidence precedence
and a deterministic rule unaffected by repeated instances of the same evidence.
Do not let replicated weaker timestamps outvote a human date.

**Pinning test:** Duplicate an existing component member carrying a conflicting
weaker date; assert unchanged per-year totals and existing candidates' scores.
Include both archived and unarchived components. The current “1,000 copies”
test (`ArchiveAngelCoverageTests.swift:283`) creates a NEW duplicate group and
expects one extra recording; it does not test duplication of an existing group.

**Closed by f2dcfbaf** — test `ArchiveAngelCoverageTests.copyMultiplicityNeverMovesARecording` (nine solo 1994 recordings + {A "1994" by Rick, B encoder-only 2026 stamp}: two more copies of B leave the per-year totals, the recording count and every existing score unchanged, archived and unarchived; a camera stamp beats five name-only copies). Fix: `ArchiveAngelEvent.DateClaim` — a recording's year is its strongest claim (person > camera/container stamp > dossier > filename; then confidence, precision, earliest year), never a vote.

## F3 — P2: Junk-score rejects manufacture actionable backlog

**Location:** `VideoScan/VideoScan/ArchiveAngel/Recommend/ArchiveAngelEvent.swift:195`–`:205`;
compare `ArchiveAngelScorer+Rules.swift:133`–`:134`.

**Source-confirmed.** The new `isActionable` checks junk disposition but ignores
the policy's junk-score floor. Its input is only the minimum duration, so it
cannot honor that floor or its configured exemptions. Files rejected as
suspected junk still increase the year backlog and boost unrelated files.

Counterexample: one clean 20-minute 1994 video plus nine independent 20-minute
1994 videos with `.unreviewed` disposition, zero stars, and `junkScore = 100`.
The nine fail the default junk-score floor, yet coverage counts ten recordings
to archive and grants the clean candidate the full +20 backlog bonus. Removing
those rejects drops the clean candidate below the bonus threshold.

**Required behavior:** Use the applicable policy checks for unwanted material
when defining actionable backlog. This finding does not require excluding
temporarily offline or resting footage; it concerns material already rejected
by the junk policy.

**Pinning test:** Add unstarred, junk-score-rejected candidates to a year below
the backlog threshold. Its actionable total and existing candidates' bonus
must not change. Also pin behavior when that floor is intentionally disabled
or an applicable exemption is configured.

**Closed by 8e33ec2d** — test `ArchiveAngelCoverageTests.junkScoreRejectsAreNotBacklog` (nine unstarred junkScore-100 files in a year of one: actionable total 1, no bonus; the floor disabled → 10; `starExempt` keeps a starred one; a `when`-narrowed floor counts files outside it; marked/suspected dispositions follow their floors). Fix: `ArchiveAngelEvent.isActionable` runs the policy's enabled junk floors (markedJunk, suspectedJunk, junkScore — starExempt and `when` honoured) through `ArchiveAngelScorer.floorFires`; the list is built once per pass.

## F4 — P2: The 400-projection budget counts group requests, not projections

**Location:** `VideoScan/VideoScan/ArchiveAngel/Prepare/ArchiveAngelJob+Evidence.swift:344`
and `:361`–`:362`; group expansion at `:160`–`:162` and `:436`–`:438`.

**Source-confirmed; no runtime group-expansion measurement performed.** The
coverage arm increments its private `projections` once when it requests an
arrival row. That row may call `liveGroupChoice`, which projects up to 64 group
members. The actual `group.projections` is added to the outer diagnostic counter
but never charged against the arm's budget. Thus the stated 400-projection
bound does not bound the new coverage tail's main-actor projection work.

Counterexample: count 2, cap 1, fresh share 0. Two higher-scored 1994 singleton
rows establish the initial band but supply only one covered slot. Below them,
eight copy groups of 64 members each arrive in one equal-score band, with
eligible representatives from other years. Finishing that band requests only
eight rows by the arm's accounting but projects 512 group members. There is no
400-projection decline. This is additional tail work, separate from the original
band's cost.

**Required behavior:** Budget actual projection work, including group members,
before expanding a group. If the remaining budget cannot finish the relevant
band safely, decline the cached path; do not accept a prefix of an equal band.

**Pinning test:** Extend the existing mid-band budget sensor with copy groups
near `maxLiveGroupMembers`, count calls to the injected projection closure, and
require the stated tail ceiling or cache refusal. Repeat under shuffled group
and record IDs. The current singleton-only projection sensor cannot expose this.

**Closed by 1c95d05a** — test `ArchiveAngelCoverageCutoffTests.groupMembersAreChargedToTheBudget` (8 groups × 64 members in one band under the 400 budget → declined within 2 + 400 + 64 projections, was 514 and accepted; 4 × 64 → the band is finished and picked, every member read; 8 id draws each). Fix: `CoverageArm.canAfford` budgets a group's members BEFORE `liveGroupChoice` expands it (an unaffordable group exhausts the budget mid-band → incomplete → decline), `CoverageArm.charge` charges what was actually projected; the group block is `ArchiveAngelJob.groupOutcome`.

## Validation and scope notes

- Re-ran the headless F1 harness successfully. It extracts unchanged
  `selectFromEvidence`, `CoverageArm`, coverage filters, and `withFreshSlots`
  from `8a86a2eb`, with explicit minimal stubs for date/model/store plumbing.
  No copy-group or floor behavior is exercised in that fixture. The “WALK”
  result is the production post-ranking selection pipeline over all four
  ranked picks, not a launched ArchiveAngelJob.
- Reproduction files are `/private/tmp/angel_coverage_repro_build.py` and
  `/private/tmp/angel_coverage_repro.swift`. Run from the repository:

  ```sh
  python3 /private/tmp/angel_coverage_repro_build.py
  swift -module-cache-path /private/tmp/angel_coverage_swift_cache /private/tmp/angel_coverage_repro.swift
  ```

- Claude reported 530 passing tests / 94 suites in Debug. This review did not
  independently rerun that suite or launch an app/test host on the active M4.
- C1's missing `markArchivedFootage` pass is present in the fallback walk.
  C2/C3/C4 remain acknowledged baseline issues and are not counted above.
- No new defect established in typed/bounded coverage policy decoding,
  synchronous snapshot stamping, launch-token separation, or the coverage-off
  pre-pass guard. Full mutation-hook coverage cannot be certified without
  tracing callers beyond the scoped files. In particular, production-path
  purge/restore invalidation merits an integration assertion; the scoped
  freshness tests are not proof that every external mutation reaches the hook.
- This branch implements Stage 2 metadata coverage. It does not implement the
  audio/visual fingerprint engine; the preliminary fingerprint-seam concerns
  are outside this review's feature diff.

No production code changed. Final merge approval should follow fixes and
regression tests for F1–F4, with the focused Angel battery rerun on an authorized
machine.
