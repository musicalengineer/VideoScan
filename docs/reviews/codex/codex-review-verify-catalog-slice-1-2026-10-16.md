# Codex review — Verify Catalog slice 1

- Range: `4b3db4844..e53468e2b`
- Credits spent: unavailable (not exposed)
- Tokens: 54555
- Finding count: 6
- Verdict: fix — the report can certify a different catalog generation, and incomplete verification can appear current.
- Run: 2026-10-17T00:59:46Z (cycle #88, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (not exposed) | Finding count: 6  
Verdict: fix — the report can certify a different catalog generation, and incomplete verification can appear current.

- **P1 — Findings and catalog hash can describe different snapshots.** [VerifyCatalogJob.swift:145](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Integrity/VerifyCatalogJob.swift:145) snapshots rows; [VerifyCatalogTiers.swift:248](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Integrity/VerifyCatalogTiers.swift:248) hashes disk later; the report combines them. **Scenario:** pause between tiers, save a change introducing a dangling relation, then resume: old clean findings receive the new generation and hash. Capture and validate the snapshot’s generation before certifying it.

- **P1 — A completed run masks incomplete or overdue built tiers.** [IntegrityReport.swift:316](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Integrity/IntegrityReport.swift:316) maps completion to `.ok`, discarding tier results and dates; [CatalogFreshnessSnapshot.swift:70](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Analyze/CatalogFreshnessSnapshot.swift:70) uses that global timestamp and full coverage. **Scenario:** verification finishes with missing full hashes, missing sound prints, or an old audit; the Integrity row becomes current. Other status rows may independently prevent the overall chip becoming green.

- **P1 — Tier 3 treats stale sound evidence as current.** [VerifyCatalogTiers.swift:190](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Integrity/VerifyCatalogTiers.swift:190) evaluates stamps without calling `staleStampReason`. **Scenario:** a Video+Audio row has digest B but a `noAudio` or zero-landmark stamp for digest A: tier 3 reports a sound contradiction while tier 4 also reports stale knowledge. An old audible stamp can likewise falsely pass tier 3. Exclude stale evidence from tier 3’s verdict.

- **P2 — Tier 5 misses invalid relations:** [CatalogConstraints.swift:215](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Integrity/CatalogConstraints.swift:215), [259](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Integrity/CatalogConstraints.swift:259) — case aliases on a case-insensitive volume, supersession cycles, and duplicate-group members with different full digests all pass; path identity, acyclicity, and duplicate-group consistency are unchecked.

- **P2 — Catalog read failure passes verification:** [VerifyCatalogTiers.swift:271](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Integrity/VerifyCatalogTiers.swift:271) collapses an unreadable existing catalog into “not on disk”; with clean rows, tier 5 returns `.ok` instead of `couldNotCheck`.

- **P2 — Partial report publication leaves contradictory outcomes:** [IntegrityReport.swift:227](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Integrity/IntegrityReport.swift:227) publishes latest before dated; if today’s dated destination is a directory, latest records completion while [VerifyCatalogJob.swift:219](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Integrity/VerifyCatalogJob.swift:219) marks the job Failed.

The remaining attacks hold within the inspected scope: no direct catalog mutation, save, or media open; report publication and prescribed logging are the writes. Partial/failed audits produce `couldNotCheck` without decision counts. Read-only-folder failure retains findings, logs OUTCOME, and outranks Stop. Stop finishes the current tier; Pause waits between tiers.

Garbage, future-schema and truncated reports are rejected. Dated filenames use the local publication date, so midnight selects the new day and same-day runs replace that day’s copy. The cap retains the first 5,000 in tier/rule ordering for fixed input order; totals count all emitted findings.

Status sums decisions, uses one-day cadence, distinguishes missing from unreadable reports, and routes decisions through `verifyAgain`. Band ordering is by decision count. **Current-content** tier-3 contradictions appropriately require human inspection and therefore red; the stale-evidence case above does not.

The scale test uses TimingBudget with a **two-second base ceiling**, not 0.5 seconds. No tests were executed because they write files. Tier-1 production digest validation and legitimate save-generation/`.prev` behavior remain unproven: their implementations are outside the allowed files.

Other listed UI/menu/runner integration and MOPS-15: **read, no additional findings**. No files written.

## Brief

# Codex brief: Verify Catalog, slice 1 (read-only integrity process; the report is its only write)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~800 words.

**One sentence (Rick, 2026-10-16):** the catalog is verified on a schedule, each tier leaves a dated "verified at", the chip reads it, and the process checks but never fixes.

**Design:** `docs/design/integrity_first_2026_10_16.md` (§2 rules, §3 tiers, §3a the mapped checklist, §4 the report, §6a proof ladder). GH #327 (truth), #328 (integrity then SQLite).

**Range:** `4b3db4844..e53468e2b` on `main` (merge `e53468e2b`; the work is `2a43601e4`). Read with `git show e53468e2b:<path>`. Paths under `VideoScan/VideoScan/`.
- `Integrity/CatalogConstraints.swift` — `IntegrityRow` projection; `CatalogConstraints.Rule` (11 tier-5 rules + the tier-4 stale-stamp rule, a table with words); `check(rows:events:)`, one static func per rule.
- `Integrity/CatalogFileHash.swift` — streamed SHA-256 of catalog.json (1 MiB chunks), generation from the first 4 KB, `Comparison` (firstRun / unchanged / changedExpected / changedSameGeneration / changedGenerationUnknown / notOnDisk).
- `Integrity/IntegrityReport.swift` — `IntegrityTierResult` (hand-written Codable `{kind,count|words}`), `IntegrityTier`, `IntegrityFinding`, `IntegrityReport` (findings capped 5,000 + total), `IntegrityReportStore` (latest + dated copy via `AtomicFilePublish`; strict reader), `IntegrityReportFacts`.
- `Integrity/VerifyCatalogTiers.swift` — `VerifyCatalogSnapshot` (Sendable, one O(records) pass on the main actor), tiers 0 (from `catalog-audit.json`) / 1 (whole-file digest coverage; `v1:` never counts) / 3 (sound stamp vs header) / 4 / 5; 2 and 6 "not built yet".
- `Integrity/VerifyCatalogJob.swift` — the MFO job (START / tier lines / OUTCOME through one sink; Stop after the current tier; Pause between tiers; the report write; failed > stopped); `MediaFileOperationsCenter.startVerifyCatalog`.
- `Integrity/VerifyCatalogDetailView.swift`, `VerifyCatalogMenuItem.swift`; `Analyze/AnalyzeCyclers.swift` (`.integrity`, `integrityJobs`), `Analyze/CatalogFreshnessFacts.swift` (`integrity` facts), `CatalogFreshnessSnapshot.swift`, `AnalyzeRunner.swift`, `AnalyzePanelView.swift`, `CatalogStatusBand.swift` (door `.verifyAgain`), `MediaOps/MediaFileOperations.swift` (kind `.verifyCatalog`), `App/VideoScanApp.swift`; `docs/practices/invariants/MediaOps.md` MOPS-15.
- Tests: `VideoScan/VideoScanTests/VerifyCatalogTests.swift` — 7 suites / 40 tests (constraints per rule; tiers; report round-trip + poisoned; 100k rows + 2k events 0.5 s; job incl. read-only folder; status; source sensors; TRUTH: the five P0 shapes produce findings).

**Attack (prove with file:line or say it holds):**
1. READ-ONLY: anything in `Integrity/*` that writes other than the two `AtomicFilePublish` calls in `IntegrityReport.swift`; any catalog row mutation; any media open; any save of the catalog triggered as a side effect (e.g. through a model property setter). The job must never leave the catalog dirty.
2. TRUTH OF THE TIERS: tier 1 counts a row "identified" only by a whole-file SHA-256 (contentFixity or archiveFixity, 64 hex, algorithm sha256) — can a `v1:` or an MD5 count? Tier 3 "header says sound the print never heard" — a `noAudio` stamp on a Video+Audio row vs a `fingerprinted` stamp with 0 landmarks vs a stamp for a DIFFERENT digest than the row's current one (stale) — are they told apart and is the stale one tier 4, not tier 3? Tier 0 reads `catalog-audit.json`: a partial or failed audit must be `couldNotCheck`, never `ok`, never red by itself.
3. THE RULES (tier 5): name a false positive each rule can raise on a legitimate catalog (two live rows at one path with different case on a case-insensitive volume; a promotion row whose source was legitimately removed from the catalog; `supersededByID` chains; a `.missing` row whose lifecycle is `.cataloged` — which `lifecycleMirror` intentionally allows) and a true violation each rule misses.
4. THE REPORT: the strict reader on garbage / future schema / a truncated file; the dated-copy naming across midnight and across two runs in one day; the 5,000 cap — does the total still count every finding and is the cap deterministic (which 5,000)? `catalogSHA256` + `catalogGeneration`: a "changed with the same generation" finding — can a legitimate save produce it (same generation written twice? the `.prev` rotation?).
5. STATUS: `.integrity`'s verdict — needsDecision = sum across tiers; cadence 1 day; storeUnavailable only when the file EXISTS and cannot be read; `verifyAgain` door; the band's words name the worst tier first. Can the chip go red from a tier the person cannot act on (e.g. tier 3's 519 headers)? Say whether that is the right colour per §3 of the status design (red = a person must look).
6. FAILURE MODES: read-only catalog folder (the report cannot be written) → row Failed, findings kept, OUTCOME logged; Stop mid-tier; a snapshot taken while a save is in flight; the 100k budget on a slow runner (TimingBudget used?).

**Do only this:** findings against 1–6 (P1 first), each with file:line and a one-line failure scenario; then at most three P2/P3 one-liners. Out of scope: tiers 2 and 6 (not built), the nightly schedule / launch argument, Fix Links, wording.

**Do not explore outside the files listed above and their tests.**


## Closure (Manager, 2026-10-16 night — fix `c4945e07e`, merged `1da4f41a3`)

All six closed RED FIRST (10 new tests, 34 issues red on main; then 65 tests in 10 suites green, Debug; the
100k + 2k constraints sensor with three more rules: 640 ms of a 2 s budget).
1. **P1 findings vs catalog hash on different generations** — the snapshot carries the store's generation; the
   hash tier compares it with the file's header. A mismatch: the report says `catalogChangedDuringRun`, the
   hash is recorded but `catalogHashCertified == false`, the tier-5 line and OUTCOME say "findings describe
   generation N; the file on disk is generation M — run again", outcome stays completed, Catalog Status goes
   yellow. Resume never re-snapshots (comment at the pause). Pin `findingsAndHashDescribeOneGeneration`
   (pause, rewrite at N+1, resume).
2. **P1 a completed run masks incomplete tiers** — `IntegrityReportFacts` derives from the BUILT tiers (0, 1,
   3, 4, 5): needsDecision summed → red; any notRun / couldNotCheck / changed-during-run → yellow naming the
   tier; `lastCompleted` is the OLDEST built tier's verifiedAt so the one-day cadence judges the stalest; tiers
   2 and 6 appear only as "tiers 2 and 6 not built" (new additive `FreshnessRow.note` in Core). Pin
   `verdictFromTheBuiltTiers` (five hand-built reports: red, yellow ×3, green with the note).
3. **P1 tier 3 counts stale stamps** — a stamp whose digest is not the row's current one is excluded from tier
   3 (tier 4's finding) and counted as "no current sound print" → couldNotCheck, never ok. Pin
   `tier3JudgesOnlyCurrentStamps` (stale silent → tier 4 only; current silent → tier 3; stale audible →
   unverified).
4. **P2 three missing tier-5 rules** — `pathAliasByCase` (two live rows differing only by case; the words say
   "on a case-insensitive volume", a decision because a case-sensitive volume can hold both),
   `supersessionCycle` (visited + settled sets, one finding per circle, dangling left to `lineageTargetsExist`),
   `duplicateGroupDigestsAgree` (live members with different whole-file digests). Rule count 10 → 13; pins one
   red/green each.
5. **P2 unreadable catalog.json passes** — `CatalogFileRead { notOnDisk | unreadable(words) | hashed }`; exists
   but unreadable → tier 5 couldNotCheck(1) with the errno words; `CatalogFileHash` sizes by `fstat` on the open
   descriptor and throws on a short read. Pin `unreadableCatalogFileIsCouldNotCheck` (chmod 000, skipped as root).
6. **P2 partial report publication** — the dated copy publishes first; latest only after it succeeded; a failure
   leaves the previous latest standing and the job Failed. Pins `datedCopyFirstThenLatest`,
   `datedCopyFailureFailsTheJobAndKeepsTheLatest` (a directory at the dated path).
Schema: `IntegrityReport` schema 2 (three new keys defaulted when reading schema 1; schema 3 refused) — pin
`schemaVersionTwo`. Not in scope, noted: the detail view does not yet show `catalogHashCertified` (the tier-5
line carries the words); tiers 2 and 6.

## Closed

Closed by `1da4f41a3` at 2026-10-17T01:28:06Z. 3 P1 + 3 P2 closed red-first (10 new tests); report schema 2
