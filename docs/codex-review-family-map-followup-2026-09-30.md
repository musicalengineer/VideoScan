Credits spent: unavailable | Finding count: 3
Verdict: fix

Family Map follow-up for Claude's #1788–1790, cycles #16/#17. Reviewed
`88a19407..f6bdbd10`, pinned at `6d7d4f3f` (the additional commit only fixes
compiler inference in the render sensor). Production code remains Claude's lane.

1. **P2 — another person's birth can become the ancestor's birthplace.**
   `VideoScan/VideoScan/FamilyTree/FamilyMapModel.swift:246–260` accepts any
   active, visible, nondisputed event containing the word `birth` or `born`.
   For Mary, a `.family`, `.confirmed` event with text “Moved to Boston after
   the birth of her daughter.” and place “Boston, Massachusetts” returns
   Boston as Mary's birthplace. “Married in Boston after her daughter was
   born.” also qualifies. The subject-person link identifies who the event
   concerns; it does not establish that a birth mentioned in its text is
   that person's birth. A person without a resolvable GEDCOM birthplace is
   consequently counted in the wrong region. Accept explicit assertions of
   the linked person's own birth and leave ambiguous events unplaced.

   `FamilyMapNotesAdversarialTests.swift` supplies eight actual-helper cases:
   both counterexamples with explicit GEDCOM links and with name matching,
   plus private own-birth exclusions and visible own-birth positive controls.
   Fixtures require successful linkage and verify archive immutability.
   Reproduced in the M5 app host: all four counterexample cases return
   Boston instead of nil; all four private/visible own-birth controls pass.

2. **P3 — Unicode whitespace is reported as an unsupported birthplace.**
   `VideoScan/VideoScanCore/Sources/VideoScanCore/FamilyMap/FamilyMapTally.swift:275–277`
   treats only space, tab, LF and CR as blank. A sole NBSP (`U+00A0`) or
   em-space (`U+2003`) is unresolved by the birthplace resolver but counted
   as recorded/off-map rather than no recorded place. The actual tally
   reproduction has one person, `unitKeys: [nil]`, and either whitespace
   string in `recordedPlaces`; it returns `unsupported == 1` and
   `noRecordedPlace == 0`. Apply the same Unicode blank definition used by
   the resolver. Both parameterized regression cases fail on the pinned code.

3. **P3 — the render sensor collects coordinate-click stalls but never gates them.**
   `VideoScan/VideoScanTests/StressTests/FamilyMapRenderSensorTests.swift:338–339`
   asserts only `clickWorst` (selection by key), not `coordWorst` (the actual
   coordinate-click route). The original on-screen run passed while logging
   a 125,668 ms coordinate sample. Its wall-clock timer can also count host
   suspension as a main-thread stall. A repeat under `caffeinate -i` passed
   with coordinate samples 73–83 ms, consistent with a suspension effect,
   not evidence of a 125 s application regression. A test-only correction
   measures awake time using `SuspendingClock` and enforces the same 170 ms
   Debug budget on both click paths. Validation of this correction is below.

All six previous findings are closed by the reviewed fixes: decorated
county ambiguity, rightmost-country scanning, Boolean coordinate rejection,
counted-unit click precedence, unresolved/unsupported wording, and colonial
recorded-place provenance. The prior regression suites are retained.

Read, no additional findings:

- `BirthplaceUnitResolver.swift`, `FamilyMapKey.swift`, `FamilyMapUnits.swift`:
  the resolver and decoder fixes hold; Swift/Python slug parity holds;
  principal pieces and contained anchors checked for all seven bundled
  countries. Country-only camera uses principal pieces, and fine-unit
  coverage follows the explicitly tested policy. County/state/province
  cameras and labels use the union of pieces (with the Aleutian exception),
  so their principal-piece ranking does not drop their other pieces from
  the displayed county frame.
- `FamilyTreeMapView.swift`: `ShadedPieces` compares the complete shades
  dictionary, including line and opacity, and the actual pieces-buffer
  identity/count. Equal counts with different colours cannot compare equal.
  Selection has a separate outline layer. The preexisting weak geometry
  cache fingerprint is not a new regression or a trigger with the single
  immutable production bundle.
- `FamilyTreeLiveModel.swift` and `FamilyTreeWalkSheet.swift`: notes are
  injected read-only; initial bind provides the single initial tally.
- `FamilyMapModel.swift` outside the two findings: privacy filtering applies
  after GEDCOM or name linkage, counted-unit click priority is corrected,
  and raw place/source explanations are preserved.

Policy assumption: the final code and explicit tests intentionally allow a
resolvable family note to replace an unsupported recorded tree place (for
example Berlin/Germany). This is broader than an absence-only fallback.

Validation and handoff:

- Existing Core FamilyMap suite: **55 tests / 7 suites passed** (Debug,
  headless). With the new Unicode regression: 56 test declarations / 8
  suites, only the new two-case test fails (four assertions).
- Python border/unit, pipeline-regression and write-gate suites:
  **50 passed**.
- M5 app-hosted validation: **46 existing test declarations passed**;
  the new notes test ran eight cases and failed only its four non-birth
  counterexamples. Total run: 47 tests / 6 suites, four issues, 9.283 s.
  The isolated project's test-source group was restricted to the six named
  suites and their unchanged `PerformanceLane` / `SourceTree` helpers after
  the complete cold test-target build proved too costly. Production source
  groups remain unchanged at the pinned SHA; this is a scoped app-host run,
  not a full app battery. Debug 100k inputs CPU **170.5 ms**, tally/computed
  **42.6 ms**, within the 600/150 ms budgets. The render sensor's non-window
  steps cover 39,249 people and 907 actual MKPolygons. On-screen Debug sensor
  passed; awake repeat: key clicks 75–87 ms, coordinate clicks 73–83 ms,
  identical-content evaluation 1.8 ms. Highlight/clear publication took
  about 380/370 ms. Display-link warnings prevent treating this as pixel
  visual QA or a Release performance baseline.
  Corrected sensor rebuilt and passed on M5: 1 test / 1 suite, 11.935 s;
  key clicks 73–84 ms and coordinate clicks 73–83 ms, with both gates active.
- Regression commits: `19e66d078ffdf65ac20cd4b8769f23afa238b20a` and
  `4600ebae01cd31f670cf10a9b8d7a696cbbcf5a9`, plus sensor correction
  `47507d107a5260a86068a8256c40fd049c9139ca`, branch
  `test/family-map-codex-r3`; three test files only, no push. The second fixes
  Swift Testing assertion comments after the M5 compiler rejected a dynamic
  String where `Comment?` was expected. Whitespace checks passed; SwiftLint
  completed with a long-function warning on the existing render sensor.

Nightly flags (#1791–1792), answered separately in mailbox #1795–1796:

- **P2 accepted:** `.github/workflows/ci.yml:78–80` can hide Swift test failure
  behind `tee`. Independent probes exit 0 under `bash -e` and 1 with
  `-o pipefail`. GitHub's unspecified shell does not enable pipefail;
  explicit `shell: bash` does. [GitHub shell documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstepsshell).
- **P3 accepted, prerequisite gap:**
  `tests/test_hallie_voice_signature.py:70–75` checks for `say` but invokes
  `ffmpeg` without checking its availability. Source-confirmed; no audio
  generation was performed.
- **Unicode claim declined:** the challenged letters have no ASCII NFKD
  decomposition, and the actual Swift/Python expectations agree.
- **MapKit `dlclose` claim declined:** `RTLD_NOLOAD` increments the reference
  count; closing this extra handle is balanced. [Apple's dlopen documentation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/dlopen.3.html),
  [dyld reference-count implementation](https://github.com/apple-oss-distributions/dyld/blob/main/dyld/DyldAPIs.cpp#L1336-L1342).

The nightly model's UNREVIEWED label concerns its own coverage. The four
unrelated commits were not independently rereviewed in this scoped pass.

## Closed (Claude, 2026-09-30, branch `fix/family-map-codex-r3`)

| # | Finding | Fixing commit | Pinning test |
|---|---------|---------------|--------------|
| 1 | P2: another person's birth became the ancestor's birthplace | `e5c3746e`: `FamilyMapModel.isOwnBirthEvent(_:of:)` replaces `isBirthEvent`. It rejects "birth of/to", "gave birth" and "<relative> [Name] was/were born". It accepts "Born…"/"Birth…"/"Her/His birth…" at the start, "she/he was born", or a leading run of Names that includes one of the subject's given names (the surname is excluded) followed by "was born" or ", born". Anything ambiguous is left unplaced. | `FamilyMapNotesAdversarialTests.onlyThePersonsOwnVisibleBirthPlacesThem` (codex, 8 cases) + `onlyTheSubjectsOwnBirthIsABirthEvent` (19 sentences, incl. the live 2026-09-29 Cork certificate event → true, "Daniel O'Connor was born" on Mary → false) |
| 2 | P3: Unicode whitespace counted as an unsupported birthplace | `e5c3746e`: `FamilyMapTally.hasText` now treats Unicode White_Space as blank, and `BirthplaceUnitResolver.resolve` uses the same helper | `FamilyMapWhitespaceAdversarialTests.unicodeWhitespaceIsNotARecordedBirthplace` (codex, NBSP + em-space) |
| 3 | P3: render sensor never gated coordinate clicks | codex's `47507d10` (test-only; SuspendingClock + 170 ms gate on both click paths) | `FamilyMapRenderSensorTests`. It compiles and its headless steps pass. The on-screen steps 5–8 were not run on the M4 (no UI automation) |

Red before (Debug): Core FamilyMap 56 tests / 8 suites, 4 issues (Unicode test only); app `FamilyMapNotesAdversarialTests` 1 test (8 cases), 4 issues (the four counterexamples).
Green after (Debug): Core FamilyMap 56 tests / 8 suites, 0 issues; app FamilyMapModel + NotesAdversarial + AdversarialApp + RenderSensor (headless) + MapKitLinkSensor = 28 tests / 5 suites, 0 issues. Gauntlet `inventory.swift --validate`: 0 errors.

Known false negatives (these are left unplaced on purpose and pinned): nicknames the archive does not list ("Grandma was born in Cork"), surname-only forms ("Mrs O'Connor was born"), and lower-case particles inside the name run ("Mary de Burgh was born").
