# Status — rewritten, never appended

*Updated 2026-10-26 (afternoon). Rick corrects this file; agents read it at session start.*

## This week's theme
**Stability before the Ultra** (Rick, 10/19). Swift 6 everywhere is done (10/25). Provenance is now designed and Phase A is built (Rick, 10/26: "design and implement"). No FamilyArchive rescan until Rick says so. **Main is local-only since 10/25 — nothing is pushed until Rick says "happy".**

## Landed on local main 10/26 (not pushed)
- **#387 catalog open:** version/integrity/FK checks run inside the writer's first `BEGIN IMMEDIATE`; a refused open deletes nothing; close protection (`NO_CKPT_ON_CLOSE` via the one-function C target `CSQLiteCloseGuard`, + `PERSIST_WAL`) is the writer's first act. Codex #151 closing pass: merge, 0 findings. Residue (a foreign writer committing *during* our open) → #389.
- **#386 read-only doors:** a WAL catalog with no `-wal` gets an empty one (create-only, resolved path, DB's mode) or a refusal that says why. `Store/SQLiteWALSidecar.swift` is reusable.
- **Provenance design:** `docs/design/provenance_retroactive_2026_10_26.md` (phases A–E, F cut; four rulings in DECISIONS).
- **Provenance Phase A — Catalog ▸ right-click ▸ Provenance ▸ Find Master (sound):** read-only MFO job over the sound-print sidecar (opened `SQLITE_OPEN_READONLY`); every verdict is the existing pair matcher's; weak overlaps collapsed, never hidden; unreadable prints are never a negative. Fresh-eyes review Good; findings fixed. Acceptance (synthetic, 5 containers): recall 1.000. Real data: index ≈0.5 s Release, 0.02–0.5 s per search. **Waiting on Rick's Debug spot test.** Follow-up: wire `SQLiteWALSidecar.prepareForReadOnlyOpen` into `AudioFingerprintStore.init(readingOnly:)` (TODO(#386) in code).

## In flight
- **Adversarial P2s (nightly 10/26) — branch `fix/adversarial-p2-2026-10-26`:** Migrate never says "safe / retire" without proof; ⌘⌫ proves the surviving copy at the move; one process-wide `RemovalReservations` (by st_dev+st_ino; leaving / relied-on) across every media removal door; git's racily-clean rule in `ContentFixity.describesFileNow`. Codex #150 block → closing block → round 3 running. **Rick's call:** rule 2 read literally means a fresh full re-hash of every stamped survivor at each ⌘⌫ move (~1–3 s/GB SSD, 10–20 s per 2 GB clip on USB HDD, estimated); today it is stored SHA-256 + live stat under the racily-clean rule. Also: should `VolumeSafety.isSafe` stop treating Aging drives as safe app-wide (today only the retire words exclude them)?
- **Committer lost-write branch `fix/committer-lost-writes-codex141`:** Codex round 3 block/3 (narrow same-content-insert and stale-sibling edges). Parked; only bites with two writers on one catalog. Finish as a focused task.
- **#383 editor caches:** waiting on Rick: Tidy Catalog…, confirm, then Skip Small Files back on.
- **Spot tests waiting on Rick (Debug):** Archive tab shows 144 Masters; #375 nickname (Timmy) in Organize; Archive no-sound mark (#345); People row removal; arrow keys in lists; Find Master.
- **Swift 6 (#376):** 10/26 02:00 nightly on the Swift 6 tree: 12,460 passed, 2 failed — both machine-timing tests (#381, #385); no crashes. Close #376 and retire `docs/design/swift6_migration_2026_10_25.md` once those two are fixed or Rick calls it. Analysis lane still not installed (`bash scripts/install_analysis_lane.sh`, M4, rota 04:30).
- **Issues open from 10/25–26:** #384 ledger atomicity · #385 laptop-dependent timing tests · #389 foreign writer during open · #377 floor gap (unit stage runs ~67 fewer app tests than its floor) · #378 · #379 · #380 · #381.
- **Step G (JSON gone):** finish or schedule. Cutover-audit P1s: #338, #339.
- **VideoScanModel split (#337, P1):** plan → Rick's go → slices.

## Next (in order)
1. Codex round 3 on the adversarial-P2 branch → merge or fix.
2. Rick: "happy" → `scripts/run_sensors.sh` on HEAD → push main.
3. Rick's spot tests above; commit his Charter edits.
4. Provenance Phase B (picture timeline v2) needs schema v13 approval; C1 needs v14 approval (design doc §schema).
5. #378, #377, #381, #385.

## Ultra (arrives Tue 10/27; dev setup Wed 10/28)
`scripts/install_dev_tools.sh` on a clean Mac (Rick: Xcode, GUI apps, Homebrew, `gh auth login` first). Then TB5 bridge + 10 GbE to the M4. **Before the catalog moves:** `migrate_data.sh --from <M4 TB-bridge IP>` (its catalog checks are uncommitted and need their Codex pass); verify how the catalog identifies a volume moved between Macs (UUID vs device number); `defaults write Rick-Breen.VideoScan CatalogSyncMasterHostname RicksUltra.local` or the Ultra launches as a viewer; recreate the STEAM symlink. Add the Ultra to `scripts/nightly_rota.json`. The M4 stays untouched as fallback until the Ultra has run green for a week.

## Dates
- 2026-11-01: off-site copy plan due.
- 2026-11-05: cloud session credits expire.

## Open rulings wanted from Rick
1. Schema v13 (`picture_prints`, Phase B) and v14 (provenance tables + veto trigger, Phase C) — design doc.
2. Provenance gate at **ingest** (Charter §2.2) or at **Promote** (10/22); hard or soft for the first month; role list; July 2026 device chain.
3. ⌘⌫ survivor proof: fresh re-hash per move, or stored SHA-256 + racily-clean stat (above). Aging drives app-wide.
4. Charter: sampled hash = hint only; Triage keep / fold / cut.
5. #327 remainder; People engines; Archive Angel; Hallie; two-copy edit conflict policy.
