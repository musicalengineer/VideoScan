# Codex brief: Catalog Status, phase 3 (UI + snapshot; not data-risk)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~800 words.

**One sentence (Rick, 2026-10-16):** the Catalog tab shows, at a glance, whether what the catalog knows is current, and Content Analysis says what needs fixing with one button per item.

**Design:** `docs/design/catalog_status_freshness_2026_10_16.md` (§2, §2.1, §3, §4). The policy is pure (`VideoScanCore/CatalogFreshness.swift`, reviewed in cycle #78). This pass is the app half.

**Range:** `b03c3ce6b..9ddfcec14` on `main` (merge `9ddfcec14`; the work is the commit under it). Read with `git show 9ddfcec14:<path>`. Paths under `VideoScan/VideoScan/`.
- `Analyze/AnalyzeCyclers.swift` — three new registry cases `.filePresence`, `.fullHashes`, `.soundPrints`, FIRST in registry order.
- `Analyze/AnalyzeCoverage.swift`, `Analyze/VideoScanModel+AnalyzeCoverage.swift` — the integrity kinds counted in the existing one-pass off-main coverage computation (full hashes: `storedFullDigest != nil`, a sampled `v1:` hash does NOT count; sound: `audioFingerprint` stamp fingerprinted or noAudio; presence from `catalog-audit.json`).
- `Analyze/CatalogFreshnessFacts.swift` — reads `catalog-audit.json` (lastCompleted, outcome, partial, counts → needsDecision) and the sound sidecar's openability; missing/garbage marker → neverRan, never a crash.
- `Analyze/CatalogFreshnessSnapshot.swift` — ONE `ObservableObject`, equality-gated; rows → `FreshnessPolicy` verdicts → summary; running state from the MFO center / runner; publish only on change.
- `Analyze/CatalogStatusBand.swift` — the band at the top of the panel: colour, headline, one line per non-green item with ONE button (yellow Run now; red: Fix Links… disabled "coming next" / Run again / Fingerprint again); "Update everything stale"; while a kind runs, the line mirrors the MFO row's collapsed state (same job object the MFO window observes; Pause/Stop; "See details").
- `Analyze/CatalogStatusUpdateQueue.swift` — starts `staleKinds` one at a time through the center, integrity first.
- `Analyze/AnalyzeRunner.swift`, `Analyze/AnalyzePanelView.swift` — Run now for the three kinds starts the EXISTING jobs (`startCatalogAudit`, the full-hash backfill, the fingerprint backfill); freshness words + dot per row.
- `Catalog/CatalogStatusChip.swift`, `Volumes/VolumeTableTotalsFooter.swift` — the chip on the totals strip reads the summary headline ("Catalog Status: …"); click opens Content Analysis.
- `Catalog/CatalogToolbar.swift`, `Catalog/CatalogAnalyzeMenu.swift`, `Catalog/CatalogStatusMenuItem.swift`, `App/VideoScanApp.swift` — the Content Analysis dot; the Analyze menu's first row = the summary; Catalog ▸ Catalog Status…; one launch log line when red.
- `Catalog/CatalogAuditSheet.swift`, `Volumes/VolumesWindow.swift` — the Storage tab's older bookkeeping check retitled "Check Totals…".
- `Model/VideoScanModel.swift` (+12: the snapshot owner), `MediaOps/MediaFileOperations.swift` (+4), `MediaOps/MediaFileOperationsWindow.swift` (+7: open at a row).
- Tests: `VideoScan/VideoScanTests/CatalogStatusFreshnessTests.swift` (8 suites, 30 tests: rows, facts, words, 100k scale inside the coverage budget, snapshot equality gating, update queue, source sensors, structure), `AnalyzeCoverageTests.swift` (extended). 77 tests in 13 suites green on main (Debug).

**Attack (prove with file:line or say it holds):**
1. OBSERVATION DISCIPLINE: no view body touches `model.records` / iterates records; the chip, band, menu row, dot and panel rows observe ONLY the one equality-gated snapshot (and the MFO job object for the running mirror). Name any per-record work on the main actor in a body, any second `@Published` fan-out, or a publish that fires per catalog save without a change.
2. ONE ENGINE: Run now / Update everything stale / the band buttons start the existing jobs through `MediaFileOperationsCenter` with the model's own markers; nothing starts a second audit / backfill while one runs; the queue never starts a kind twice; a kind that is running is excluded from `staleKinds`.
3. TRUTH OF THE COUNTS: full-hash coverage excludes sampled `v1:` hashes and rows with a digest for a different size; sound coverage counts noAudio stamps as covered; presence `needsDecision` comes only from a COMPLETED last run (a partial or failed run never claims rows point at nothing); a garbage `catalog-audit.json` is neverRan, not red, not a crash; the sidecar-unavailable red fires only when the file exists and cannot be opened (an absent sidecar before the first run is yellow/neverRan).
4. THE MIRROR: the band's running line and the MFO row read the same job state; Pause/Stop from the band do what the MFO row's do; no duplicated progress bookkeeping.
5. WORDS: yellow headline "N things need attention", red "Needs a decision: …" (Rick 10/16); the chip prefix "Catalog Status: "; green is quiet (no pill); the launch line is one line and only when red.
6. Retitle: no remaining "Audit Catalog" wording on the Storage tab's bookkeeping door; the Catalog menu's "Audit Catalog…" is the tier-0 job.

**Do only this:** findings against 1–6 (P1 first), each with file:line and a one-line failure scenario; then at most three P2/P3 one-liners. Out of scope: the audit job's own correctness (cycle #78/#79), Fix Links, nightly wiring, `FreshnessPolicy` itself.

**Do not explore outside the files listed above and their tests.**
