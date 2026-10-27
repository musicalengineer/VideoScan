# Status — rewritten, never appended

*Updated 2026-10-26 (night). Rick corrects this file; agents read it at session start.*

## This week's theme
**Stability before the Ultra** (Rick, 10/19). Swift 6 everywhere is done (10/25). Provenance is now designed and Phase A is built (Rick, 10/26: "design and implement"). No FamilyArchive rescan until Rick says so. **Main is local-only since 10/25 — nothing is pushed until Rick says "happy".**

## Landed on local main 10/26 (not pushed; mirrored to origin `overnight/2026-10-26`)
- **Provenance roles (Rick 10/26):** policy `docs/guides/provenance_roles.md`; no file is a designated Master yet. **Provenance ▸ Set Role** built: table `provenance_roles` (schema **13**, append-only), one engine through the commit door, Inspector role line; Archive shows "Archived" instead of "Master". Codex: fix/2 → closing merge/0. ⚠ First launch of this build migrates catalog.sqlite 12 → 13; a Mac on an older build (the laptop viewer) refuses a v13 catalog until it is rebuilt. **Waiting on Rick's Debug spot test** (steps in the merge commit 74eb37b33's branch report).
- **Find Master UI:** green "FOUND this clip in N recordings (M files)" headline, hits grouped by spot, ▸ chevron on MFO rows with detail, selectable detail text, right-click Copy Summary.
- **Small fixes:** #378 and #385 closed (timing budgets judge growth/relative cost; wall-clock product budgets strict only on the reference nightly); Find Master's read-only sound-print open restores a missing -wal.
- **Adversarial P2s (nightly 10/26) — merged after 4 Codex rounds (final: merge, 0 findings):** Migrate says "safe / retire" only when every file is proven (adoptions included: source stamp current + fresh destination hash); ⌘⌫ knows a copy only by whole-file SHA-256 and proves it on disk at the move; one process-wide `RemovalReservations` (st_dev+st_ino; leaving / relied-on) across every media removal door incl. Transcode replace; git's racily-clean rule in `ContentFixity.describesFileNow`. Rick ruled 10/26: trust stored SHA-256, re-hash only when needed; Aging drives unchanged (DECISIONS). New words to see: Migrate "Some files are not proven safe yet", row "Backup not proven"; ⌘⌫ hold reasons. Not covered: family-tree file trashing in People/ (not media).
- **#387 catalog open:** version/integrity/FK checks run inside the writer's first `BEGIN IMMEDIATE`; a refused open deletes nothing; close protection (`NO_CKPT_ON_CLOSE` via the one-function C target `CSQLiteCloseGuard`, + `PERSIST_WAL`) is the writer's first act. Codex #151 closing pass: merge, 0 findings. Residue (a foreign writer committing *during* our open) → #389.
- **#386 read-only doors:** a WAL catalog with no `-wal` gets an empty one (create-only, resolved path, DB's mode) or a refusal that says why. `Store/SQLiteWALSidecar.swift` is reusable.
- **Provenance design:** `docs/design/provenance_retroactive_2026_10_26.md` (phases A–E, F cut; four rulings in DECISIONS).
- **Provenance Phase A — Catalog ▸ right-click ▸ Provenance ▸ Find Master (sound):** read-only MFO job over the sound-print sidecar (opened `SQLITE_OPEN_READONLY`); every verdict is the existing pair matcher's; weak overlaps collapsed, never hidden; unreadable prints are never a negative. Fresh-eyes review Good; findings fixed. Acceptance (synthetic, 5 containers): recall 1.000. Real data: index ≈0.5 s Release, 0.02–0.5 s per search. **Waiting on Rick's Debug spot test.** 

## In flight
- **Committer lost-write branch `fix/committer-lost-writes-codex141`:** Codex round 3 block/3 (narrow same-content-insert and stale-sibling edges). Parked; only bites with two writers on one catalog. Finish as a focused task.
- **#383 editor caches:** waiting on Rick: Tidy Catalog…, confirm, then Skip Small Files back on.
- **Spot tests waiting on Rick (Debug):** Archive tab shows 144 Masters; #375 nickname (Timmy) in Organize; Archive no-sound mark (#345); People row removal; arrow keys in lists; Find Master; Migrate summary words; ⌘⌫ on a duplicate pair.
- **Swift 6 (#376):** 10/26 02:00 nightly on the Swift 6 tree: 12,460 passed, 2 failed — both machine-timing tests (#381, #385); no crashes. Close #376 and retire `docs/design/swift6_migration_2026_10_25.md` once those two are fixed or Rick calls it. Analysis lane still not installed (`bash scripts/install_analysis_lane.sh`, M4, rota 04:30).
- **Issues open from 10/25–26:** #384 ledger atomicity · #389 foreign writer during open · #377 floor gap (unit stage runs ~67 fewer app tests than its floor) · #379 · #380 · #381.
- **Step G (JSON gone):** finish or schedule. Cutover-audit P1s: #338, #339.
- **VideoScanModel split (#337, P1):** plan → Rick's go → slices.

## Next (in order)
1. Rick: "happy" → `scripts/run_sensors.sh` on HEAD → push main.
2. Rick's spot tests above; commit his Charter edits.
3. Provenance next: machine role suggestions + rejected-suggestion veto (needs approval); Phase B picture timeline (schema approval; numbering moves to 14+ since provenance_roles took 13).
4. #377, #381.

## Ultra (pickup and bring-up Tue 10/27)
Run sheet and machine roles: `install_videoscan_dev_dependencies/MIGRATION_PLAN.md` § Tuesday 10/27 (updated 10/26). Ultra = Rick's machine, catalog master, all media drives local; M4 = headless test/LLM host (nightly stays on the M4). No family media over SMB from the M4 (read-only model jobs only). Ultra SSD budget: ≥ 400 GB free, fast copies in one 800 GB-quota APFS volume. `migrate_data.sh` catalog checks are committed (Codex #122 closed). 🔴 Main must be pushed before the Ultra's clone.

## Dates
- 2026-11-01: off-site copy plan due.
- 2026-11-05: cloud session credits expire.

## Open rulings wanted from Rick
1. Schema v13 (`picture_prints`, Phase B) and v14 (provenance tables + veto trigger, Phase C) — design doc.
2. Provenance gate at **ingest** (Charter §2.2) or at **Promote** (10/22); hard or soft for the first month; role list; July 2026 device chain.
3. Charter: sampled hash = hint only; Triage keep / fold / cut.
4. #327 remainder; People engines; Archive Angel; Hallie; two-copy edit conflict policy.
