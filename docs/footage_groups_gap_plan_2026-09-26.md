# Find Similar Footage — Phase 1 staged plan (gap-closure)

## Headline for Rick: the premise "nothing is coded yet" is stale

Phase 1 is substantially **landed on main** (commits `2227d111` → `d4a266a2`, 2026-09-23..25, codex reviews #1674/#1717 closed). What exists, verified in the tree:

- **Data model** — `/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/FootageMembership.swift`: `FootageMembership` (groupID, groupSize, confidence Identical/Confirmed/Likely/Possible, role, rank, likelyOriginalID, originalInCatalog, evidence[], scannedAt, algorithmVersion) and `FootageDecision` (same/notSame, symmetric on both records). `VideoRecord.footage`, `.footageDecisions`, `.proAppsMediaIdentifier` are additive optionals; DTO writes keys only when present; ledger kind `footageDecided`; decisions survive rescans (`FootageRescanSurvivalTests`).
- **MFO verb** — `MediaFileOperationKind.findSimilarFootage`; `/Users/rickb/dev/VideoScan/VideoScan/VideoScan/FootageGroups/FindSimilarFootageJob.swift`: 5 phases, off-main via `@concurrent`, pause/stop at phase and apply-slice boundaries, one-run-at-a-time queueing, stale-result discard on a newer human answer, Logger `Rick-Breen.VideoScan/findSimilarFootage` + videoscan.log START/OUTCOME. Pure core `FootageGrouping.swift` (union-find, strongest-edge-first, cap 64, Possible never chains, date-prefix cannot-link, bounded name window); `FootageOriginality.swift` (reason-printing scorer); `FootageStem.swift` (normalizer). Sampled hashes nominate only; Identical requires two *current* whole-file digests (stat-checked).
- **Catalog UI** — `FootageGroupBadge` in the table cell (O(1)), Show ▸ **One Per Footage** (`FootageOnePerGroup.filter`, in the event-driven filter pass), right-click **Find Similar Footage…** sheet with per-member evidence chips, Reveal/Play, Same / Not the same / Forget.
- **Archive Angel** — policy `copies.collapseBy: [footageGroup, duplicateGroup, nameAndDuration]`, `prefer: [userKeeper, footageOriginal, best]`; rules v12 `markArchivedFootage` (group whose original is archived is done); **Keep footage groups current** (façade auto-run, default ON, `considerFootageRun`) landed in `9d7df1e8`/`27b9b9ea`.
- **Tests** — `FootageGroupingTests` (stem, evidence, components, originality, guitar/Dicky/Christmas-1990 sensors, duration-alone sensor at 20k/100k, 100k scale ≤ 3 s Debug), `FootageCodex1674Tests`, `FindSimilarFootageJobTests` (Codable legacy round-trip, isolated-model job, poisoned stale answer, read-only refusal, AA collapse, ffprobe `test_*` mediaIdentifier fixture), `FootageCalibrationTests` (opt-in, on a catalog copy).

So the plan below is **what is missing against Rick's stated goal**, not a rebuild. Stages are independently mergeable.

---

## Stage 0 — Verify + calibrate (0.5 day)

- Run `FootageCalibrationTests` against a fresh catalog copy (env `FOOTAGE_CALIBRATION_CATALOG`/`_OUT`) and report groups by confidence, largest group, `originalNotInCatalog`, refused counts. The wise-design table showed only **12 of 9,055** records grouped on 9/25 00:15, *before* auto-run landed — Rick needs the post-auto-run number.
- Confirm the Angel's last automatic run stamp in the log ("Keep footage groups current — START").
- Files: none touched. Tests: existing. Risk: none. **Needs Rick:** wise-design decisions **#2** (auto-run, already default ON) and **#6** (export-as-original counts as done) are still formally open.

## Stage 1 — Job-level scale + drive safety (1 day)

Gaps: the 100k tests cover the pure core and the filter, not the *job* path; and phase 2 stats every record with a usable `contentFixity`, off-main, but with no reachability gate.

- Add `FootageJobScaleTests`: 100k synthetic records through `footageInputsAndProbes` (main actor) + `applyFootage` slices; budget via `PerformanceLane.debugCeiling`; sensor that the longest single main-actor hold (snapshot, and one 2,000-record slice) stays under ~150 ms (the VolumeStatusCache discipline).
- Gate the stat probes by volume reachability (existing `VolumeReachability`/`VolumeStatusCache`) so an unmounted or stale SMB path is skipped, not stat-ed; log skipped count in `FootageRunSummary`.
- Files: `/Users/rickb/dev/VideoScan/VideoScan/VideoScan/FootageGroups/VideoScanModel+FindSimilarFootage.swift`, `FindSimilarFootageJob.swift`, new test file. Dimensions: Scale, Isolation (poisoned reachability), Sensor. Risk: low.
- **Decision (Rick):** resume-after-quit. Delete Duplicates saves a plan; this verb finishes in ≈1–2 s on the real catalog and every apply slice is a complete answer, so I recommend **no saved plan** — document it in the job header instead.

## Stage 2 — Archive Angel coverage across years/events (2–3 days) — the real gap

Today's dedup is per *recording*: footage group, duplicate group, name+duration, and `onePerFamily` (folder + base stem). Nothing spreads a batch across **years/events**; Stage 4 of the wise design ("timeline-gap signal") has **no code** (`grep timelineGap|stratif` → nothing). Five differently-named Thanksgiving-1994 edits in different folders still pass as five picks.

- **Event key**: add `eventKey` to `ArchiveAngelCandidate` = resolved date at day precision (userDate → embedded → inferred; year-only when that is all) + volume-independent folder base. Add a second `onePerEvent` pass beside `onePerFamily` in `ArchiveAngelScorer` with rejection `sameEventAsPick`.
- **Stratified batch**: policy-driven `coverage.maxPerYearPerBatch` (default 2) and a `coverage.backlogBonus` rule kind: years with deep unarchived backlog and few archived files earn points (the 9/25 table: 2010 156/27, 2011 77/7, 2023 70/2…). Computed once per sweep as `[year: (unarchived, archived)]` in the existing O(n) pre-pass in `VideoScanModel+ArchiveAngelSweep` (same place `archivedGroups` is built), never in `selectFromEvidence`'s inner loop.
- **Duration band**: verify `durationTier` in `ArchiveAngelScorer+Rules.swift` rewards 5 min–2 h and penalises < 2 min / > 2 h as Rick said; make the band edges policy keys.
- Readiness explanation lines for both rejections (`ArchiveAngelReadinessExplanation.swift`).
- Files: `/Users/rickb/dev/VideoScan/VideoScan/VideoScan/ArchiveAngel/Recommend/ArchiveAngelScorer.swift`, `ArchiveAngelScorer+Rules.swift`, `AngelPolicyDefaults.swift`, `ArchiveAngelRecommendations.swift`, `ArchiveAngelCandidate+Record.swift`, `Prepare/ArchiveAngelJob+Evidence.swift`, `docs/archive_angel_policy.md`.
- Tests: `ArchiveAngelCoverageTests` (logic: 5 Thanksgiving-1994 variants + 4 other years → one 1994 pick and the others; year cap; backlog bonus ordering), `ArchiveAngelCoverageScaleTests` (100k candidates, pre-pass ≤ 1 s), `AngelRecommendationPolicyTests` additions (unknown keys refused, older policy.json still loads), sensor: a batch of 10 never holds > `maxPerYearPerBatch` of one year; parity test that `RankKey` order is unchanged when coverage is off.
- Risk: medium — touches the pick band (codex #1643 A4 determinism); keep coverage as a *post-band* filter plus points, never a band mutation. **Needs Rick:** policy.json schema gains keys (additive, bump `rulesVersion` → 13, evidence.json re-scored — that is the existing path).

## Stage 3 — Fingerprint seam (1–1.5 days, no fingerprints yet)

`FootageGrouping.run` builds edges only from `FootageInput`; `Reason` is closed with a fixed confidence; `Edge` uses array indices. Later audio/visual edges need one door.

- `FootageGrouping.ExternalEdge { a: UUID, b: UUID, reason: Reason, detail: String }` and `Options.externalEdges: [ExternalEdge]`; `edges(_:stats:)` maps UUID → index (drops unknown ids, counts them) and appends before `components`. Union-find, cap, date rules, stats, evidence text all apply unchanged.
- New `Reason` cases now, unused: `.audioFingerprint` (`.likely`), `.visualFingerprint` (`.likely`), `.sharesAudioOnly` (`.possible` — "same event, other camera" never chains). Add `isContentBased` for future rules.
- Job seam: `protocol FootageEvidenceSource { func edges(for ids: [UUID]) async -> [ExternalEdge] }` in `AngelSeams`-style file; the job gains an optional phase "Reading fingerprint evidence" between phases 2 and 3 (progress slice 0.10–0.15). Default source returns []. `algorithmVersion` stays 2 (no answer changes).
- Tests: `FootageExternalEdgeTests` (an injected audio edge joins two singletons at Likely; sharesAudioOnly obeys the one-hop rule; a "not the same" cannot-link beats a fingerprint edge; unknown ids counted, not crashed; 100k inputs + 50k external edges within the 3 s budget; determinism sensor: same result with `externalEdges: []` as today).
- Files: `/Users/rickb/dev/VideoScan/VideoScan/VideoScan/FootageGroups/FootageGrouping.swift`, `FindSimilarFootageJob.swift`. Risk: low. **Needs Rick (later, not now):** the fingerprint store (`fingerprints.sqlite`) and engine (Chromaprint brew dep vs ShazamKit) — v2 Phase 2 decisions; the seam itself adds no dependency or schema.

## Stage 4 — Catalog polish (0.5–1 day, optional)

- "Footage" table column (group size / role) sortable; Showing summary line "N groups hidden" when One Per Footage is on; sheet: "Play both" opens both files in one gesture. All O(1) per row; the summary count comes from the filter pass, not `body`.
- Tests: `CatalogShowingSummaryTests` addition, snapshot of the badge text; sensor: no `records` iteration in the table cell (existing perf memo pattern).

## Scale summary (100k records)

- Pure grouping 1.9 s Debug (budget 3 s, `FootageScaleTests`); One-Per-Footage filter < 1 s; both off the view body. Snapshot + apply on main actor are the only O(records) main-thread work — Stage 1 pins them. AA `archivedGroups` pre-pass and the new coverage pre-pass are one O(n) pass per sweep in the sweep builder. Badge and sheet are O(1)/`.task`.

## Decisions that need Rick

1. Accept that Phase 1 is landed and this is a gap plan (Stage 0 numbers first).
2. No resume-after-quit for this verb (Stage 1).
3. Coverage policy keys + rules v13 (Stage 2) — the piece that answers "five Thanksgiving 1994s".
4. Wise-design open items #2 and #6.

### Critical Files for Implementation
- `/Users/rickb/dev/VideoScan/VideoScan/VideoScan/FootageGroups/FootageGrouping.swift`
- `/Users/rickb/dev/VideoScan/VideoScan/VideoScan/FootageGroups/VideoScanModel+FindSimilarFootage.swift`
- `/Users/rickb/dev/VideoScan/VideoScan/VideoScan/ArchiveAngel/Recommend/ArchiveAngelScorer.swift`
- `/Users/rickb/dev/VideoScan/VideoScan/VideoScan/ArchiveAngel/Recommend/AngelPolicyDefaults.swift`
- `/Users/rickb/dev/VideoScan/VideoScan/VideoScan/ArchiveAngel/Prepare/ArchiveAngelJob+Evidence.swift`
