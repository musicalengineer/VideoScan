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
