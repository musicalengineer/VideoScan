# September 14–15 code review and test coverage

Reviewed main **`e1d244e2380436f30d0e41f5f510897e38986cca`**. Rick requested
an independent review of recent work and a useful handoff to Claude. Production
review is read-only. Two existing atomic-publish tests were strengthened.
Rick and Claude retain the in-progress MFO/Archive Angel UI and Promote work;
those uncommitted changes are outside this review.

## Findings to address

### 1. Major: People-profile clarification loses the selected answer path

**`HallieTurnExecutor.swift:2191`**, introduced through `628de4b8`.

The new precedence branch can offer profile choices when two People profiles
own the same derived name. The continuation correctly carries the selected
profile's stable ID. However, `ArchivistGraphExecutor.swift:1049–1054` resolves
an unpinned profile by expanding its canonical name into tree matches. The
resulting ambiguity reaches `peopleTabPrecedenceResult`, whose
`selectedIdentity == nil` guard refuses the profile fallback on this second
turn. The user is sent back to the crowded tree question.

Use the existing fixture in `PeopleTabPrecedenceTests.swift:315–336`: two
profiles derive “Elizabeth Breen” and the tree has twenty Elizabeth Breens.
Select the offered “Elizabeth” profile. Its canonical name matches the crowd,
so the new profile question does not lead to that profile's answer.

**Correction:** handle a selected People profile by stable identity at this
boundary while retaining the authority of explicit GEDCOM selections.
**Regression:** continue the actual returned clarification with an offered
candidate ID; assert the selected profile answers, with no repeated tree
ambiguity. Also cover a profile removed or changed between those two turns.

Evidence is source tracing through production callers, not a fresh app/model
reproduction. The new test currently stops after the first question.

### 2. Major: Profile fallback answers the model's raw operation instead of the corrected question

**`HallieTurnExecutor.swift:2207–2209`**, introduced through `628de4b8`.

At line 1560, the graph path constructs `ArchivistGraphQuery` with the original
question, applying existing deterministic operation/relation corrections.
The new profile fallback then passes the original payload to `PeopleTab.answer`.

Example: “Where was Beth born?” arrives from the model as `.birth`; an exact
unpinned Beth profile has a birthday, and the tree has more than six unanchored
Elizabeth namesakes. The corrected query is `.birthPlace`, but the fallback
uses the raw `.birth` branch in `HallieTurnExecutor+PeopleTab.swift:485–487` and
reports a birthday as an answered question. The correct result when the profile
has no birthplace is an honest missing-place answer, not its birth date.

**Correction:** carry the resolved operation and relation into the profile
answer. **Regression:** cross the original question with deliberately incorrect
model operations, especially birthplace versus birth and biography versus birth,
through `HallieTurnExecutor.execute`, not only the field-guard initializer.
This is source-confirmed; no fresh real-model replay was performed.

### 3. Confirmed metadata regression: restricted file mode is widened on replacement

**`AtomicFilePublish.swift:322,314`**, introduced by the atomic-save migration.

The durable writer creates a fresh inode with mode `0644` (subject to umask)
and renames it over the destination without preserving destination metadata.
The previous Foundation replacement preserves original permissions by default,
as documented in the installed SDK's `NSFileManager.h`.

**Executed scratch reproduction:** create a `0600` destination, set the probe
process's umask to `022`, then call actual `AtomicFilePublish.write(.fullFsync)`.
The resulting mode is **`0644`**. The preservation assertion fails as expected.
No real sidecar was read or changed; this is not evidence that Rick currently
has restricted sidecars or that private data was exposed.

**Correction:** preserve an existing destination's intended mode before publish;
decide deliberately which other destination metadata/ACL semantics are required.
Keep the plain rename and unique temporary file. Add the scratch mode-preservation
case permanently with the correction.

### 4. Durability contract gap: directory flush errors are silent

**`AtomicFilePublish.swift:349–353`**.

The `.fullFsync` documentation promises the parent directory is flushed for
forced-reboot durability. `syncDirectory` silently returns on directory-open
failure and ignores the flush result. A caller receives ordinary success even
when persistence of the newly published directory entry was not established.

This is explicitly implemented as best effort after publication. A correction
must distinguish **published but durability unconfirmed** from **not published**;
blindly treating it as an ordinary failed write could mislead retry/rollback code.
At minimum, make the failure diagnosable and align the advertised contract with
the outcome. Add injected open/flush failures to exercise this boundary.

The directory flush succeeded on the scratch APFS test. No failed barrier,
power-loss loss, or torn-payload event was reproduced. This is an error-reporting
and assurance gap, not evidence that plain rename is the wrong mechanism.

## Coverage repaired in this review

`AtomicFilePublishSensorTests.swift` previously suppressed all errors during
2,000 concurrent publishes, accepted any final text beginning with `w`, and
searched for wrapper temp suffixes even though that test created plain `.tmp`
files. Its in-flight registry test likewise discarded errors from 800 writes.

Both now record synchronized success/failure observations, require every write
to succeed, require the final bytes to equal a complete expected payload, and
reject every non-destination file left in the scratch directory. The wrapper
test retains its per-test in-flight registry scope. No production code changed.

**Negative control:** a temporary copy of the publisher was made to reject
1,999 of 2,000 publishes, allowing only one success. The committed old test
incorrectly passed; the strengthened test failed on errors, success count, and
leftover files. Mutation remained in disposable harness copies; production was
never modified. This establishes that the revised test catches a failure the
original missed, rather than merely duplicating implementation details.

## Executed validation

All fresh validation was **Debug, headless**, using scratch data and bounded
concurrency. These are correctness checks, not Release performance baselines.

| Check | Result |
|---|---|
| Two strengthened tests, exact test file and actual unchanged publisher in a temporary Swift package | 2/2 passed; 0.557s; 2,800 operations |
| Existing core `PreviewDiskCacheLockLocationTests` | 3/3 passed; 0.006s |
| Rejected-publish negative control against old test | Incorrectly passed; 0.185s |
| Same negative control against strengthened test | Correctly failed; 0.194s |
| Restricted-mode preservation probe | Expected failure: 0600 became 0644; 0.021s |
| RAM-disk script syntax | `bash -n` passed |
| Patch whitespace | `git diff --check` passed |

Evidence artifacts:

- `/private/tmp/videoscan-atomic-review-20260915/green.log`
- `/private/tmp/videoscan-test-review-20260915-core-final.log`
- `/private/tmp/videoscan-atomic-review-20260915/permissions.log`
- `/private/tmp/videoscan-atomic-review-20260915-negative-old/negative.log`
- `/private/tmp/videoscan-atomic-review-20260915-negative-new/negative.log`

The harness executed the edited behavioral tests, not the complete app test
target. No VideoScan app, UI tests, model replay, disk mount/eject, or Xcode
preference change was performed. The full app-target integration run remains
for an explicitly routed test machine.

## Other reviewed changes and remaining coverage

- **Tree UUID assertions, `cdcdcb9e`: sound.** The revised profile-ID lookups
  match both production map construction and UI consumption. They restore
  meaningful assertions, including negative lookups that had passed vacuously.
  The added assertion that pinning preserves profile ID is useful. Inspected
  65 tests across the affected files; not freshly executed here. A targeted
  search found no remaining literal-name `derivations` or `treeLinkBadges`
  lookups in app tests; that is not proof against every possible vacuous test.
- **Date report, `e1d244e2`: valid repair.** An absent sidecar is permitted only
  for zero unwound rows. Existing synthetic tests still require recovery
  sidecars for real changes. The live-catalog mtime check remains a limited
  sensor: an unrelated running app save can fail it, and equality does not
  prove all real-store artifacts were untouched. Keep isolated synthetic
  safety tests authoritative; live-data reports are environment-dependent.
- **People precedence tests:** 23 source-inspected tests mostly call the real
  executor and cover exact/fuzzy exclusions, profiles and pins, two-name
  collapse, and selectable versus crowded namesakes. The two missing sequences
  above are material. No execution of these 23 tests is claimed here.
- **Scale:** the new test header's blanket “scale n/a” needs qualification.
  `PeopleTab.answer` calls `taggedVideoCount` over `presenceRecords`
  (`HallieTurnExecutor+PeopleTab.swift:461,644–649`). Add a 100k-record sensor
  through this newly reached fallback. The existing 100k-profile *roster* test
  exercises a different operation/input. No new media-opening behavior is
  introduced, so the media-matrix dimension is inapplicable to these patches.
- **View extraction, `5c6cdaa9`:** the inspected card and banner diffs retain
  gesture ordering, identifiers, conditions, and action closures. No new
  behavioral finding from source review; no fresh UI execution.
- **RAM-disk consolidation/manual operation, `c63c299f`/`ff9a4670`:** the mount
  check, stray-directory refusal, and explicit teardown match the stated
  manual-use intent. No new blocking finding in the inspected script. Real
  mount and preference behavior was not exercised during this review.

### Previously identified policy question

Claude's mailbox #1507 already flags that `!arrangement.offersChips` blocks
pinned profiles as well as unpinned ones. A crowd of six or fewer can therefore
bypass a human pin. The rationale talks specifically about *unpinned* profiles;
the code does not make that distinction. I agree this deserves an explicit
pin-versus-namesake rule and a small-crowd pinned test. It is separate from the
two concrete new routing failures above and is not claimed as a new discovery.

## CI and handoff

[Hosted CI for this exact snapshot](https://github.com/musicalengineer/VideoScan/actions/runs/35034751235)
built successfully but failed scale/media tests and timed out after 20 minutes.
The last active test in the inspected failure log was
`tripAcrossCountryShapeCatalogsExactlyTheValidMedia`; heartbeat output continued
until timeout. No diagnosis that this test alone caused the stall is asserted.
The new People-precedence suite was not observed in that failed-step log.
[Python CI passed](https://github.com/musicalengineer/VideoScan/actions/runs/35034751278).
These are distinct from a successful, complete application regression run.

Claude reports that the M1 licence failure and M5 stale checkout have been
corrected and both hosts now use `e1d244e2`; this is attributed fleet context,
not a test run independently performed here. The selected headless tests above
pass, but the full regression baseline is not yet green.

Coordination: #1507 acknowledged; test ownership announced in #1508;
initial response #1509; concrete Hallie findings sent in #1510.
Recommended next work: repair the two Hallie boundaries with second-turn and
operation-correction regressions; preserve atomic-save permissions and test it;
make durability limitations observable; then run the relevant app suites on a
routed test host with nonzero test counts and complete results.
