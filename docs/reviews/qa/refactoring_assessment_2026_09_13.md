# Refactoring assessment — September 12–13, 2026

Prepared by Codex for Rick and Claude. Final source/branch check:
**September 12, 2026, 23:00:43 America/New_York**. Main remained unchanged from
the inspected inventory snapshot. This is a code assessment, not an overnight
real-model replay result.

## Bottom line

Refactor the boundaries where identity, persistent data, asynchronous work and UI
meet. Do not launch a general rewrite or impose a file-length quota. Much of this
codebase already has useful small components and substantial regression tests;
the remaining risk is often an operation that crosses several of those components.

First finish tonight's correctness fixes. Then choose **two bounded extractions**:
the People identity/persistence boundary and one Hallie session/turn boundary.
Use the existing tests as preservation contracts and add the missing cross-layer
sequence before moving the code. The other eight entries are a prioritized backlog,
not a commitment to do ten simultaneous refactors.

## Evidence and limits

- Source inventory and focused reviews: main `01d94091abd7735f36d77521e4f16ef5966b6b63`.
- 628 tracked app Swift files, **222,863 raw lines**; 34 files exceed 1,000 lines
  (5.4%). Largest: `ArchivistChatWindow.swift`, 2,720 lines.
- 616 tracked app-test Swift files, **185,186 raw lines**. This is substantial
  test code, **not a coverage percentage or proof of correct integration**.
- Counts include comments and blank lines. They cover `VideoScan/VideoScan` and
  `VideoScan/VideoScanTests`, not the separate core package, tools or CLI targets.
- Churn signal: reachable commits touching a file since August 29, not distinct
  defects or independent changes. Hallie conversation/executor have 34/33 touches;
  lineage 29, graph executor 28, coordinator 25, tree model 24, chat window 23.
- SwiftLint is not installed. No compiler-derived cyclomatic complexity or fresh
  app coverage was collected. Structural risk below comes from inspected control
  flow, mutable ownership, durable side effects and recent concrete regressions.
- Independently ran `python3 -B -m unittest discover -s tests -p 'test_hallie_*.py'`:
  **52 passed**, 0.249 seconds reported by unittest. These are harness tests, not
  52 real-model questions. No VideoScan app, model, UI tests or live-data mutation.
- Tonight's branch reviews are documented separately in
  [the review ledger](overnight_reviews_2026_09_12.md). A branch's passing test
  count is attributed to Claude unless this report explicitly says otherwise.

### Review handoff at the snapshot

| Change | Status | Revision / message |
| --- | --- | --- |
| Photo-preserving People rename | Merged; Claude independently approved | `984bb560`, #1410 |
| Exact Delete Volume Catalog plan | Merged; Codex approved | main `01d94091`, #1435 |
| Off-main attestation logging and merge ordering | Approved, not yet merged | `cd801d16`, #1439 |
| Date propagation plus new automatic cleanup | HOLD on descendant cleanup and recovery-file overwrite | `7514bb56`, #1439 |
| People UUID migration and consumers | HOLD on remaining wrong-person and photo-link paths | `c56bd2bc`, #1440–1442 |

The final HOLD findings were delivered to Claude, with a receipt/status request
in #1443. No subsequent response or replacement revision had arrived by the
23:00 check. They are not implicit approvals. Refactoring recommendations below
do not replace those concrete fixes or authorize live-data repair.

## Ranked top ten

Sizes are individual representative files at the snapshot, not module totals.
Priority weighs damage from mistakes, shared responsibilities, change frequency,
and the difficulty of testing the actual operation—not size alone.

| Rank | Module / representative files | Raw lines | First useful boundary |
| --- | --- | ---: | --- |
| 1 | People identity and persistence: `PersonFinderTypes`, `PersonFinderModel`, `POIStorage` | 1,300 / 904 / 345 | Explicit identity resolution plus guarded profile operations |
| 2 | Hallie turn/session orchestration: `HallieTurnExecutor`, `+Conversation`, coordinator, chat window | 2,231 / 1,509 / 1,156 / 2,720 | One turn context and a testable response/action commit boundary |
| 3 | `ConfirmPersonSheet` | 1,832 | Holdout review runtime separated from panes |
| 4 | Catalog mutation/projection and actions: model, scan-target pane, table extension | 1,545 / 960 / 1,754 | Revision-tagged aggregate coordinator; explicit action plans |
| 5 | Date and dossier provenance: `VideoScanModel+DateInference`, `+DossierPropagation` | 416 / 472 | Content-identity/provenance policy separated from writeback |
| 6 | Family-tree lifecycle and photo edits: live model / view | 1,908 / 1,789 | Generation-tagged loading and captured photo-edit sessions |
| 7 | Archive Angel job and sweep | 610 / 369 | Per-entry preparation; separate trigger policy later |
| 8 | `FamilyAssetStore` | 1,744 | Immutable folder inventory and explicit attribution result |
| 9 | `HallieLineageQuestion` | 1,833 | Ordered detection, resolution and traversal/answer stages |
| 10 | Hallie replay/grading infrastructure | 802 / 255 / 177 | Shared corpus/result contracts and pure grading |

### 1. People identity and persistence

`PersonFinderTypes.swift:472` starts a profile domain model that also handles
encoding (`:648`/`:707`), storage, legacy identity upgrades, caching and images
(`:801–1079`).
`PersonFinderModel.swift:536–620` additionally resolves the active person and
writes recognition settings/profile data. `POIStorage.swift:236` owns migration;
the pending UUID branch expands this responsibility considerably beyond its main
snapshot size.

**Why first:** tonight's failures cross exactly these boundaries: namesake
resolution, quarantined folders, migration recovery, imported UUIDs and photos.
Protecting one save method did not protect Delete, bundle import, or open review
sheets. That is evidence for a shared operation boundary, not just smaller files.

**Small first change:** separate profile value/codec from storage, and centralize
the result of identity resolution (`resolved`, `missing`, `ambiguous`,
`quarantined`). Scope the first PR to guarded save/delete; integrate import and
review operations in subsequent PRs using the same contract. A
present-but-missing UUID must never silently become a name lookup. Preserve the
People tab's authority for contemporary biography and vitals. No storage-schema
redesign is needed to start.

**Preservation tests:** `POIProfileFileStoreTests`, `POIProfileRenameIntegrationTests`,
`POIUndoDeleteTests`, `POIFamilyNameFieldsTests`, `FamilyKinshipTests`; pending
branch adds `POIUUIDMigrationTests` and `TwoRichardsConsumerSensorTests`.
Before extraction, pin actual writes with two same-name people, a stale selected
UUID, quarantined deletion, interrupted migration and dereferenced photo links.
An assertion that a helper reports ambiguity is not an operation-isolation test.

### 2. Hallie turn/session orchestration

The executor holds contracts and state (`HallieTurnExecutor.swift:245–858`), route
dispatch and graph execution (`:1303`), and biography composition (`:1679`).
`HallieAppTurnCoordinator.swift:869` captures context and `:1014` executes it.
`ArchivistChatWindow.swift:1027`, `:1277`, `:1465`, and `:1608` combine requests,
response commit, playback and remote interaction in the view.

**Risk:** a correctly resolved person can be lost between layers; a late result
can also update transcript, cards, speech or media after the session has changed.
Splitting each file into more extensions without clarifying ownership would not
address this.

**Small first change:** make one immutable turn context carry resolved person,
profile/tree generation, conversation revision and cancellation identity through
execution. Extract one response/action commit owner with injected sinks. Keep
translation, rendering and existing executors in place. Do not simultaneously
replace routing, prompts or models.

**Preservation tests:** `HallieIdentitySurvivesExecutionTests:77`;
`HallieAppV2IntegrationTests:503` selection changes, `:624` clarification, `:705`
cancellation. Its 100k test at `:792` repeats one object and injects execution:
useful for capture cost, not end-to-end graph/profile cost. Window wiring checks
at `:826`/`:851` inspect source strings; shell replay uses `--no-actions`.
Add behavioral late-response/cancel/chip/action tests and a profile/tree generation
change between clarification and execution. Preserve the existing actor model.

### 3. ConfirmPersonSheet

The sheet owns phase policy/state (`:104–315`), rendering (`:353–899`), holdout
queue and offline/copy resolution (`:914–1452`), HDD prefetch (`:1454–1535`),
candidate scoring (`:1537–1623`) and label/catalog writes (`:1625–1718`).

**Small first change:** extract only the holdout runtime into a session/controller
with injected queue, person identity and media/copy facts. Keep panes and the
candidate phase unchanged. Enforce write eligibility at the operation boundary,
not just a disabled button.

**Preservation tests:** `HoldoutReviewQueueTests`, `HoldoutCopyResolverTests`,
`HoldoutOfflinePrefilterTests`, `HoldoutReadAheadTests`, `HoldoutAnswerWriteChainTests`,
`UnifiedReviewSessionTests`. Add the actual open-sheet sequence where People
changes after presentation and before a label write; assert no wrong-person write.

### 4. Catalog mutation, projections and actions

`VideoScanModel.swift:12` fans record-array changes into many caches/sweeps;
`:1295` is another mutation funnel. `CatalogView+ScanTargetsPane.swift:156–311`
mixes catalog projections, filesystem probing and off-main grouping with a
view-owned scheduler (`:880–944`). `CatalogContent+Table.swift:452–1608` combines
row menus and many domain actions with table rendering.

**Small first change:** extract projection scheduling and its revision-tagged
snapshot, leaving pane layout alone. As a separate small PR, move one action
family behind explicit input/result types. Retain the new exact Delete Volume
Catalog plan; never derive destructive scope from a coalesced display cache.

**Risk evidence:** tonight's stale confirmation defect is fixed, but broad
invalidation on unrelated metadata edits still creates expensive fan-out. The
earlier target-facts construction had a records × targets² path, but that has
already been improved. At this snapshot the bound is targets² setup plus
records × targets projection. The 100k/20-target nested fixture pins that
improvement, but does not establish a budget across varying target counts.

**Preservation tests:** `ScanTargetRecordFactsTests`, `CatalogStorageTotalsTests`,
`DeleteVolumeCatalogPlanTests`, `CatalogPurgeTests`. Same-count mutation and
target removal/replacement after a gesture already have sensors; preserve them.
Add varying-target-count budgets and queued late-completion sequences. Do not change
deletion policy as part of the extraction.

### 5. Date and dossier provenance

This is deliberately a high-ranked **small-file** candidate.
`VideoScanModel+DateInference.swift:162–240` decides content groups and propagation;
`:264` runs the pass and `:382` publishes it. `+DossierPropagation.swift:40–137`
separately groups by partial MD5 and copies selected evidence; `:218` performs
legacy cleanup. Similar-looking identity decisions serve different purposes.

**Small first change:** define a shared, explicit content-evidence decision and
separate pure propagation/repair plans from mutation, recovery-sidecar persistence,
invalidation and logging. Keep grouping for display/accounting distinct from
authority to copy facts. Any stored-format change needs Rick's approval.

**Risk evidence:** tonight found conflicting-hash propagation, an intermediate
donor bridge and cleanup of only part of a bad provenance chain. The new date
guards alone do not cure OCR already copied by the dossier path. Treat that as a
known correctness follow-up, not as proof a larger rewrite is necessary.

**Preservation tests:** `InferredDatePropagationTests`, `DateInferenceSensorTests`,
`DossierPropagationTests`. Pin repeat passes, same-year conflicting full dates,
missing/cyclic donors, descendant cleanup, backup-write failure, unique recovery
files, preservation of user dates, and settled-group cost. Fix first; extract second.

### 6. Family-tree lifecycle and photo editing

`FamilyTreeLiveModel.swift:569` coalesces requests, settings/revisions, tasks and
publication; `:603` chooses loader/build inputs and `:714` handles recompilation.
`FamilyTreeView.swift:1705–1782` separately owns photo overrides, encoding,
persistence, imports and refresh notification.

**Small first change:** extract the load-coordination logic into immutable
requests and generation-tagged outcomes, leaving graph installation on the model.
Photo editing is a second independent seam: capture person/archive/source identity
and return one explicit completion to the view. Neither requires discarding the
tree cache or changing the threading model.

**Preservation tests:** `FamilyTreeModelReuseTests`, `FamilyTreeRecompileButtonTests`,
`FamilyTreeLaunchBundleTests`, `PersonPhotoOnePerPersonTests`, `ReferencePhotoImporterTests`.
Add deterministic three-request sequencing with different settings, archive loss
during loading, reverse-order photo completions and selection changes mid-import.
These sequences are not established by the inspected suites.

### 7. Archive Angel job and sweep

`ArchiveAngelJob.swift:122–250` combines preflight and candidate selection;
`:326–458` runs multi-stage per-entry preparation; `:485–609` settles cancellation
and filesystem transitions. `ArchiveAngelSweep.swift:120–358` owns four task
handles, rerun state, debounce/periodic triggers and sliced scoring/persistence.

**Small first change:** extract per-entry preparation returning step outcomes and
output record IDs. Keep job state, checkpoints, selection and settlement in the
job. Later separate sweep trigger policy from scoring; do not redesign both at once.

**Preservation tests:** `ArchiveAngelCandidateProjectionTests`,
`ArchiveAngelExplicitPickTests`, `ArchiveAngelPlanSettleTests`,
`ArchiveAngelSymlinkSourceTests`, `ArchiveAngelSweepTests`, `HelperAudioRepairTests`,
`TranscodeTests`, and `MediaFileOperationsTests`.
Direct orchestration is the missing assurance: test failures/cancellation at each
stage, restart from a checkpoint, unavailable source, and exactly-once settlement.
For a later real-media change, use the production logic on a bounded media-matrix
batch and report wall time/throughput separately from pure scorer performance.

### 8. FamilyAssetStore

`FamilyAssetStore.swift:675` adds group-document folders; `:697` reconciles alias
attribution with legacy ordering. Enumeration, identity parsing, read precedence,
write eligibility, photo selection and document lookup live together.

**Small first change:** build one immutable folder inventory and derive explicit
attribution results from it. Preserve the intentional difference between permissive
read discovery and conservative write targeting. Do not merge their policies just
because both accept a name string.

**Preservation tests:** `FamilyAssetStoreTests`, `HalliePersonGalleryStoreTests`,
`FamilyAssetIdentityDirectoryTests`. Pin alias/canonical collisions and consistent
folder attribution for photos/documents/labels from one captured inventory.
Retain serve/write-time filesystem revalidation: a captured inventory does not
make later filesystem changes atomic.
This supports the intended experience of asking about Eileen and opening her
documents without confusing namesakes or making biographies media-dependent.

### 9. HallieLineageQuestion

The file combines precedence-sensitive detection (`:154`), person/owner resolution
(`:1307`), ancestor traversal/answer shaping (`:1563`) and tree navigation/recompile
responses (`:1693`). It changed in 29 reachable commits in the measured window.

**Small first change:** extract detection and person resolution behind explicit
ordered rules, retaining existing precedence. Then extract traversal/answer shaping.
Do not replace deterministic birthplace/ancestry queries with free-form model guesses.

**Preservation tests:** `HallieLineageTests:411` birthplace subject, `:594` deep
chains, `:793` 100k provenance; `HallieBirthplaceTrailTests:624` multi-turn paging,
`:659` tree replacement, `:895` neighboring-route exclusions. These are useful
deterministic contracts. Add real-model paraphrases through app and shell with
the same captured tree/profile identities; synthetic tests do not prove that layer.

### 10. Hallie replay and grading infrastructure

`scripts/hallie_eval.py:356` runs and pairs conversations; `:511`/`:667` grade and
report them. `scripts/nightly_hallie_replay.sh:135` selects corpora and `:146`
starts lane execution; the script
combines statuses. `scripts/hallie_question_testbed.py:41` has another extraction
and human-grading representation.

**Small first change:** share corpus/result contracts and pure pairing/grading,
with separate runner adapters. Preserve command flags, recorded log formats and
nightly status semantics; schema/log-format changes require approval. Make the
relationship between harvested questions, reviewed expectations and human grades
explicit rather than treating every recorded question as a regression gate.

**Current inventory, not a run:** nightly selects **31 strict + 387 advisory**
questions. A separate **200-turn** interaction corpus is the standalone harness
default, not either nightly-selected corpus. The separate question testbed has
**67 cases with zero stored human grades** in the checked-in file. These sets must
not be added together and advertised as independently verified questions.

**Preservation tests:** the 52 harness tests ran successfully for this assessment;
`tests/test_hallie_eval.py:828–956` covers missing answers, exits, timeouts, corpus
changes, wrong-person/card constraints and duplicate IDs. The shell runner also
has `scripts/test_nightly_hallie_replay.sh` (inspected, not run here).
Keep nightly counts separate: expected/completed, strict pass/fail, advisory flags,
ungraded, incomplete/not-run, host/model/binary/tree provenance and elapsed time.
A clean lexical/structural grade is not proof of correct family reasoning.

## What I would leave alone initially

- `MediaFileOperations.swift` (1,248 lines): terminal-observation bookkeeping at
  `:691–858` is a good later extraction, with unusually useful event-flood and
  exactly-once tests in `MFOLogSummaryTests`. Below the active identity/data risks.
- `FamilyKinshipOverlay.swift` (1,595 lines): already delegates sibling derivation.
  Narrow its helper input at `:545` later; do not redo a well-tested derivation
  merely because its containing file is long.
- `PersonFinderModel+JobLifecycle.swift` (1,659 lines): the restore tail at
  `:1363–1658` is a good follow-up after People identity is settled. Existing
  `ScanJobsStorageTests`, `PersonFinderLifecycleTests`, and
  `SessionRestorePauseStateTests` give it a manageable boundary.

## Acceptance bar and morning decisions

1. Agree on the first **two** bounded PRs, one owner and one independent reviewer
   each. Claude remains implementation manager; Codex provides adversarial review.
2. Before moving code, pin the actual boundary sequence—not only helper behavior
   or source-string presence. Preserve existing public behavior and actor ownership.
3. Apply the project's five dimensions where relevant: logic, 100k scale with a
   budget, real media matrix, poisoned-state isolation, and durable regression sensor.
   Explicitly mark dimensions that do not apply to a pure extraction.
4. No changed storage formats, dependencies, threading model, live-data repair or
   mass mechanical cleanup hidden inside a refactor. Review those separately.
5. Ship an extraction when its focused preservation tests and existing relevant
   suites pass. Do not turn this list into an unlimited polishing loop.

## Reproducing the inventory

```sh
git rev-parse HEAD
git ls-files -z 'VideoScan/VideoScan/*.swift' | xargs -0 wc -l | sort -nr
git ls-files -z 'VideoScan/VideoScanTests/*.swift' | xargs -0 wc -l
git log --since='2026-08-29T00:00:00-04:00' --format= --name-only -- 'VideoScan/VideoScan/*.swift'
python3 -B -m unittest discover -s tests -p 'test_hallie_*.py'
```

Inspect the named snapshot, not a changing worktree. The unrelated local
`Package.resolved` edit was preserved throughout.
