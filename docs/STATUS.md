# Status — rewritten, never appended

*Updated 2026-11-02 (Monday, midday). Rick corrects this file; agents read it at session start.*

## Read first (five minutes)
1. **Main is `05225e33`, pushed, checkout clean; nothing red on main** (sensors GREEN 634; the four pre-existing Python reds fixed `7e224245`; gauntlet inventory validates with 0 errors). Landed today, in order: the **docs prune** (`docs/archive/` deleted, 137 files; git keeps them at tag `pre-prune-2026-11-02`; the link guard treats archive citations as history; CLAUDE.md line 33 changed — Rick reviews), **P0 #401** (scan locations credit a record only when both name the same volume UUID; five Codex passes, merge, cycle #213; issue closed; follow-up #412), and the **Catalog Status colour rule** (below).
2. **Catalog Status, Rick's ruling today (DECISIONS 2026-11-02):** a coloured line says *exactly why* and *exactly how to fix it* — "<Colour>: <cause>. Fix: <verb>" — and a finding with no clearing verb never colours a line. Database is red only for a failed check or a structural break with its verb named; yellow when older than 24 h, stopped or never run (Check Now…); green otherwise. The 19 files whose sound print measured silence are a fact (inspector: "Video+Audio · silent (measured)"), not a finding; an event member pointing at a file Rick removed is history, not a break. Rick's catalog goes green after one Check Now….
3. **Nightlies 02:00 (main `336199bb`):** Core 2,224 / 0 both Macs · App 12,78x / 2 both — the two (wording pin, Analyze Duplicates hop) fixed on main; tonight is the Release proof. **Hallie strict 56 / 56 on the Ultra**; the **M4 lane did not run** (its catalog was schema 13) — fixed by hand at 10:55: the Ultra's sealed v14 copy (generation 1282, hash verified) is the M4's catalog, the old file is in `.trash/2026-11-02-pre-v14-catalog` under its App Support. Finding: the Hallie shell reads the Mac's local catalog, and the M4 ran as a second master on a stale copy through 11/01 18:54; its defaults now name the Ultra, so the next launch is a viewer (BACKLOG H′ covers the shell).
4. **P0 triage (Rick asked):** #401 fixed and closed · #332 fixed 10/19, close after Rick plays two or three archived titles · #327: the three code items are in main; two rulings remain (below).

## Spot tests for Rick (Debug app at `VideoScan-dd/status-colour`, main `05225e33`)
- **Catalog Status**: open it before Check Now… — red names event "Matt" and says "Fix: no verb yet"; press Check Now… — green, "Integrity check passed"; the detail still lists the 19 silent tracks and the one member "kept as history"; chip "Reconciled"; the Content Analysis first row "The catalog is reconciled". Inspector on Fog 01.dv: "Video+Audio · silent (measured)".
- **Scan locations** (#401): Catalog ▸ scan targets — the Ultra's `~/Movies` row shows 0 files (its 9 were the M4's); an unplugged drive shows its own rows by volume UUID.
- Carried over: the Catalog menu's three groups and briefs; Delete Selected Files… on an Avid MXF half ("…and its N related halves", "Select Related Halves"); Family Tree on the M4 (orange banner, every write refuses); Get Family Tree never overwrites (`<name>-2.ged`); era lines ("Machine era" in the inspector, search "60s"; Status convergence "31 of 60 (51 %)").

## Next
1. **Catalog Status "Fix…" button** (Disk Utility shape): a red line's one button shows what it will change, runs it, logs it, re-checks. First verb: remove an event member whose row is truly gone. Design when Rick says the rule holds on his catalog.
2. Prompt r4 (narrowest era range the evidence supports) on held-out clips; corpus era run in Rick's Ultra windows (≈ 4,600 contents, resumable).
3. DV datecode as a deterministic bound (Phase D) after Rick's ranking ruling (DECISIONS 11/01: best machine date for born-DV footage); ExifTool date tabulation; pulldown detector.
4. #412 (content-hash backfill path-only), #408 (five gauntlet UI flows), the Hallie shell reading the viewer snapshot on a viewer Mac (BACKLOG H′).
5. Cleanup execution after Rick's ruling on the proposal (`docs/design/cleanup_and_operations.md`).

## Waiting on Rick
- **#327, two rulings** (recommendations in the issue): Promote/Tidy worklists on a sampled-hash match read "possibly archived (sampled)" and never count toward % archived; the preservation checklist reads "Sampled signature — not verified". Say OK and a worker words them; the issue closes.
- **#332**: play two or three archived titles; close if they have sound.
- **Scan locations**: an unplugged drive never seen mounted on this build shows the rows its catalog entries unanimously name until plugged in once (accepted default; "0 files on every unplugged drive at first launch" judged worse).
- Older, defaults in place: viewers show no synced rulings/bookmarks in the read-only tree; a filing interrupted by a revocation still runs its undo; Prune's detail row stays green for a re-marked copy; the Workbench discard sheet opens only on a warning; "Content Analyzer" as its own menu after a few days; background service §7 items 2–3; video-LLM §9 items 1–2; gauntlet runner policy (known issues as failures); the Codex attended-review pilot terminal run (`VideoScan-wt/attended-model-review`).

## To file
- Events tab hides an event whose only member is purged (why Rick could not find "Matt"); it should show as "empty — its file was removed" with Remove Event.
- CatalogSync `defaultMasterHostname` is still `RicksM4.local` in code (the defaults key saves it; DECISIONS 2026-10-27 says the Ultra).
- `IntegrityReportFacts.gap` counts tier 5's informational could-not-check as "unverified" (the long "not verified: tier 5 …" line); the band already excludes it.
- `scripts/warning_ratchet.py` "N compiled file(s)" counts files WITH warnings; print the compiled-file count.
- `CheckCopies.checkCopiesRegroupScope` still calls the synchronous `DuplicateDetector.affectedSubset` on the main actor; use `affectedSubsetOffMain`.
- `scripts/run_catalog_tests.sh` RED on a green tree: Core lane floor 409 vs 403 run; count by manifest.
- Era job re-analyzes files with no `era.fused` line every run; write an `era.none` observation.
- `VerifyCatalogTests.swift` is 1,403 lines (SwiftLint file_length); split by tier.
- Stale `volume_uuid` rows (6); ~330 Hallie questions never replayed; 557 Thread Performance Checker traces; `findtag-journal/` unbounded; `previewSweepEnabled` stale key; `MediaPersonLinks.swift` uncalled. `tools/codex_review.py` still writes transcripts to `docs/reviews/codex/` (#410); today's went to `.scratch/reviews/` per PROCESS §9.

## In flight
- Background step 1 merged 11/01 (`0656aee6`, schema v14): first convergence reading 51 % close enough / 88 % inside range on 60 files; the corpus runs in Rick's windows. `fix/committer-lost-writes-codex141`: parked. Swift 6 (#376): close once #381/#385 are called. Open: #384 · #389 · #377 · #379 · #380 · #381 · Step G · #338, #339 · VideoScanModel split #337 (plan → Rick's go).
- Worktrees under `VideoScan-wt/` to prune after Rick's word (never delete; `.trash/`): fix-timing-test, dv-datecode, dv-date-review, bg-step1, bg-step1-ui, docs-consolidation-b, docs-codex-fix, catalog-db-info, catalog-menu, ft-readonly, trash-pairs, fix-verify-wording, hop, docs-prune, p0-401, fix-monday-reds, status-colour. Keep `bench-a2/.scratch/` (bench runs, Rick's verdicts) and `dv-date-review/.scratch/` (DV verdicts).

## Dates
- 2026-11-05: cloud session credits expire (`docs/briefs/cloud/`, `docs/reviews/cloud/LEDGER.md` then deleted). Mid-November: grade A in every module. 2026-12 soft / 2027-01 target: Public view link for family (Charter §5).
