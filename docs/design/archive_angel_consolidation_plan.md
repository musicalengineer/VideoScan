# Archive Angel consolidation plan (DRAFT for Rick, 2026-09-22)

Rick: "we have two versions of this AA… the promote helper can go away and we should consolidate all of the logic in one place the AA… all in one software module, very modular… Then we make the UI match the workflow naturally."

## Bottom line
Two recommenders exist today and they disagree. The Helper's "ready" = *a person vouched for it and it has a year*; the Angel's "ready" = *grade A, score ≥ 100*. Worst case (a bug): the file the nudge ranks FIRST (archiveStage = Ready) the Angel rejects as "Already in the archive" (ArchiveAngelScorer.swift:516 treats stage ≥ masterAssigned as archived; Ready sorts after Master). Step one is ONE rule set; the file moves are secondary.

## Inventory (LOC)
- Helper generation ≈ 2,360: ArchiveNudge (155) + ArchiveNudgeView (~125, in ArchiveProgress.swift), AssessCopiesJob (280), AssessCopiesDetailView (881), CopyFamilyAssessor (643), CatalogContent+AssessCopies (28), HelperAudioRepair (314), ArchiveNameAdvisor (57, already shared).
- Archive Angel ≈ 7,600 (+5,900 tests): Scorer, Candidate, Attention, BufferHygiene, Plan/PlanStore/Follow, PlayHistory, LiveBatches, EvidenceStore, Sweep, Job(+Evidence), Promoter; UI: AssessmentPanel, StartSheet, ReviewSheet, ReadyDisclosure, BufferHygieneCard, UnreadableRow, RowActions, CatalogBadge, DetailView; model/MFO glue.
- Shared Promote infrastructure stays OUTSIDE the Angel and is NOT changed: PromoteToArchiveJob(+Steps), ArchivePromoteEngine, ArchivePromoteDecisions, Promote sheet(+Readiness), VideoScanModel+MasterArchive, ArchiveReadiness (its token is written into the manifest), ArchivedWhatNextSheet, ArchiveDateEntry.

## Duplicated / conflicting logic
1. Two meanings of "ready"/"nearly ready" (nudge vouch rules vs Angel grades A/B).
2. Stage contradiction (bug above).
3. Junk: nudge `junkScore < 50`, no star exemption; Angel `junkFloor = 5`, unstarred only.
4. Floors only the Angel has (< 2 min, Live Photo motion, recent phone clips, app cache, proxy, offline, resting) — why the nudge's "589" > Angel A+B.
5. Four date rules (nudge precision, ArchiveReadiness.dateState, Angel dateConfidenceKnown 0.8, sidebar Needs Date).
6. Three ways to pick "the copy" (nudge key, Angel onePerDuplicateGroup/onePerFamily/markDerivatives, CopyFamilyAssessor.recommendedInstance).
7. "Already archived?" checked in the view (promoteWouldRefusePermanently) vs isArchivedOrVersionOfArchived in the Angel.
8. Verify-then-balance audio implemented twice.

## Leaks (worst first)
- ArchiveView.swift:67-200 holds Angel state and runs the Angel's whole buffer-refresh pipeline itself (settle, scan, hygiene, forget companions, follow renames, save). Accidental.
- ArchiveView+Table.swift:56-90 hand-assembles six Angel views.
- VideoScanModel.swift:732-750 four stored Angel properties (→ one façade property).
- Catalog table/helpers/inspector read the evidence store directly (legit reads → via façade); CatalogContent+Promote reads `archiveAngel.makeLossless` from UserDefaults (accidental); VideoScanApp.swift:604 busy gate type-checks ArchiveAngelJob (accidental); MFO knows the job kind/detail view (legit plug-in → one factory); ArchiveItemVersions uses ArchiveAngelNaming.derivativeBaseStem (→ shared archive naming).
- Outbound: catalog reads (incl. O(n) `records.first { fullPath == … }` in the Job), navigation via UserDefaults "selectedTab", companion record retirement, MFO job starts, buildPromotePlan, ledger, TestEnvironment.isTestHost in defaultBufferRoot.

## Target architecture
Folder `VideoScan/VideoScan/ArchiveAngel/{Facade, Seams, Recommend, Prepare, Review, Promote, UI}` (file-system-synchronized groups → no pbxproj edits). One façade `@MainActor final class ArchiveAngel: ObservableObject`, the ONLY Angel property on the model (`model.archiveAngel`), composed from seams:

| Seam | Covers | Conformer |
|---|---|---|
| AngelCatalog | snapshot, record(id:/path:) (indexed), archived predicate, keeper policy, read-only, log, forgetRecords(paths:reason:) | VideoScanModel |
| AngelNavigator | show in catalog | VideoScanModel |
| AngelJobRunner | verify, diagnosis, balance, transcode, promote, isBusy | MediaFileOperationsCenter |
| AngelArchive | buildPromotePlan, root path | VideoScanModel+MasterArchive |
| AngelLedger | attention events | ledger |
| AngelEnvironment | buffer root, clock, defaults | — |

Façade API: Recommend (recommendations, evidence(for:), badge(for:), candidateIDs, assessNow, setContinuous) · Prepare (prepare(count:lossless:), prepare(recordIDs:)) · Review (batches, refreshBatches, followRenames) · Promote (promote(plan:) → existing Promote job) · Hygiene (clear, clearAll) · Lifecycle (launch, catalogChanged, ledgerEvents, isBusy). Every entry point logs START + result.

Public to the rest of the app: ArchiveAngel, ArchiveAngelStrip, ArchiveAngelCatalogBadgeView, ArchiveAngelMenuItems, ArchiveAngelJobDetailView, ArchiveAngelRecommendationClass. All conformances in one file ArchiveAngel/Seams/AppConformances.swift.

### Packaging
- (A) Folder + façade + ArchiveAngelBoundarySensorTests (ratchet: today's leaks listed, may only shrink, zero after S2). No build-graph change; tests keep `@testable import VideoScan`. Weakness: enforced by a test, not the compiler. **Recommended now.**
- (B) Separate SwiftPM module: compiler-enforced `internal`, but ~40 seams must exist before anything moves, views depend on app EnvironmentObjects, Testbed rewrite, Sendable friction (VideoRecord non-Sendable). **Later, for the pure core only (S6: ArchiveAngelCore in the VideoScanCore package).**

## Folding the Helper in
One pure classifier `ArchiveAngelRecommendations.classify(candidate, verdict, dateRule)`, one O(n) pass per sweep revision:
- **Ready** — passes the Angel's floor, AND (you vouched: Important or ★★+, OR grade A), AND dated to at least a year.
- **Needs a date** — same, undated.
- **Worth a look** — grade B, not vouched.
- **Not now** — C/D. **Excluded (reason)** — X.
- Batch states: **Prepared — waiting for review**, **Promoted**.
Headline: "N ready · M need a date · K prepared". One date rule (wraps RecordDateResolver; ArchiveReadiness stays authoritative for Promote). One copy chooser (parity-tested). One AudioStep.
Goes away: ArchiveNudgeView, "Archive Helper…" (menu + button), the .assessCopies MFO job + panel, AssessCopiesJob, CatalogContent+AssessCopies. Kept as an Angel view: read-only **Show Copies…** (CopyFamilyAssessor) on review rows and the catalog right-click; single-file promote = "Prepare with Archive Angel" (batch of one).

## Stages (each independently mergeable; codex reviews each)
- **S0** characterization tests only: golden plan.json fixtures decode (no stored property / enum raw value may be renamed), nudge counts + grade histogram on 100k synthetic records, readiness token unchanged, ledger kinds unchanged.
- **S1** moves + thin forwarding façade + sensor in ratchet mode — no behaviour change.
- **S2** seams + leak removal (refresh pipeline out of ArchiveView, one model property, ArchiveAngelSettings with the SAME UserDefaults keys, busy gate via seam, record(path:) index, injected buffer root with the same default).
- **S3a** classifier with a "legacy" rule set reproducing the nudge exactly (parity test); **S3b** unified rules (counts change on purpose, old→new logged once, rulesVersion 11 → re-score).
- **S4** remove Helper UI; Show Copies… stays.
- **S5** workflow UI: one ArchiveAngelStrip card, Recommend → Prepare → Review → Promote (hygiene "What next?" merged into Review); catalog filter becomes Ready / Needs a date / Worth a look.
- **S6** (optional) pure core → ArchiveAngelCore package target.

Data safety every stage: Promote engine/job/manifest/decisions journal/ArchiveReadiness token untouched; plan.json + buffer layout unchanged; evidence.json rebuildable; ledger kinds unchanged.

## Decisions for Rick
1. Folder + façade + sensor now, package for the pure core later? (recommend yes)
2. "Ready" in one sentence: passes the Angel's floor, you vouched (★★+ or Important) or it grades A, and it has at least a year? (recommend yes)
3. Stage Ready/Master: a vote to archive, not "already archived"; only isArchivedOrVersionOfArchived means archived? (recommend yes)
4. Assess Copies: keep as read-only "Show Copies…", drop the MFO job + Helper panel? (recommend yes)
5. UI names: Recommend → Prepare → Review → Promote; classes Ready / Needs a date / Worth a look; A–D letters only in tooltips? (recommend yes)
