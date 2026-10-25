# Status — rewritten, never appended

*Updated 2026-10-25 (evening). Rick corrects this file; agents read it at session start.*

## This week's theme
**Stability before the Ultra** (Rick, 10/19) **and Swift 6 everywhere** (Rick, 10/25: Swift 6 language mode, in stages, within about a week — `docs/design/swift6_migration_2026_10_25.md`, tracking #376). Feature work is paused except provenance design. No FamilyArchive rescan until Rick says so.

## Swift 6 migration — where it stands (the session-start hook prints the measured line)
- **Stages 0, 1, 2, 3, 4 merged and pushed 10/25.** Start: 460 warnings in 168 files (299 Swift 6 errors). After stage 3+4: **228 remain (50 %)** — sendable-capture 140 · main-actor 54 · sendable-conformance 27 · other 6 · deprecated 1. Core is in Swift 6 language mode (1,873 tests / 0). The app flips (stage 8) at 0.
- **In flight (worktrees, workers):** stages 5–7 split by module — A: People/ FamilyTree/ Hallie/ Model/ Shared/ (87); B: Media/ Catalog/ MediaOps/ ArchiveAngel/ Archive/ Volumes/ (47) + all test-target warnings (94). Each slice: fresh-eyes reviewer, Codex on rule-10 files, related suites, sensors GREEN, then the merging session lowers the baseline from the slice's clean logs.
- **The floor:** `scripts/warning_ratchet.py` runs inside the sensor lane (per file × category; nothing may rise). The committed baseline moves only at a merge. Every opt-out carries a `// Swift 6:` comment (`grep -rn "// Swift 6:" VideoScan/` is the audit list); the nightly census counts them.
- **Stage 2 nightly analysis lane** (merged 10/25): `scripts/nightly_analysis_lane.sh` — ratchet verify + progress, escape-hatch census, Periphery, `-strict-memory-safety`, one sanitizer kind per night (TSan / ASan+UBSan via `weekly_sanitizer.py`). **Not installed yet:** Rick runs `bash scripts/install_analysis_lane.sh` on the M4 when he wants the 04:30 slot live (rota `"analysis"`); the weekly sanitizer agents stay until the lane has run green for a week. `swiftlint analyze` is opt-in only (O(files²), >25 min).
- **Process bugs fixed on the way (10/25):** the sensor-lane GREEN stamp had never been written (empty `mktemp` index) and then never matched a commit (tracked-but-ignored files) — no push to main had passed the hook since 10/23. Fixed, red/green, `scripts/sensor_lane_stamp.sh`. Main is pushed.
- **Rulings still wanted from Rick (Charter review 10/25):** (a) §8 sampled hash is a hint only, identity is whole-file SHA-256 — one DECISIONS line; (b) provenance gate at ingest or at Promote. Rick's Charter edits + the new §3.8 Development Modes are uncommitted in his checkout.

## In flight (other)
- **P0 rescan purge (10/22) — recovered;** the 10/24 LaCieWorkspace rescan (5,642 cataloged, 5,640 hashed in full) left all 144 FamilyArchive Masters intact. **Waiting on Rick:** spot test of the Archive tab (expect 144 Masters). Follow-up #366 (P2).
- **Merged 10/24, waiting on Rick's Debug spot test:** Archive no-sound mark (#345) and People tab row removal. Follow-ups #368–#371.
- **Spot-test targets from today's slices:** Catalog People column and Relocate summary sheet text (interpolation replaced `Text +`), filmstrip / Find Person frame seeking (async image generator), People tab first load (migration state read under the run lock).
- **Nightly 10/24 GREEN:** app 12,271 / 0; Core 1,872 / 0. Hallie strict 57/67.
- **#375 nickname bug — fix merged 10/25 (Codex branch, gated here), waiting on Rick's Catalog/People spot test:** tagging lists show the family nickname; duplicate labels carry birth years. **New issues 10/25:** #377 two stale gauntlet manifest assignments; #378 two People tests assert a raw 500 ms budget (every weekly sanitizer run reads tests-failed); #379 CI publishes `periphery_aggressive: 0` while a local scan finds 1,440.
- **`test/gauntlet-prodshape`** (locked worktree): leave it to its owner session.
- **Provenance** (design under review): needs Rick's four answers before Phase 1.
- **Step G (JSON gone):** finish or schedule. Cutover-audit P1s: #338, #339, the stale-JSON-reader item.
- **VideoScanModel split (#337, P1):** coordinate with Swift 6 stages 5–7 (same files).

## Next (in order)
1. Merge slices A and B (reviewer → Codex on rule-10 → baseline → lane → merge → push); then stage 8: `SWIFT_VERSION = 6`, full suite on the fleet, Codex on the flip.
2. Rick: Archive-tab spot test; the two Charter rulings; install the analysis lane when ready.
3. #378 (two-line fix, unblocks the sanitizer lanes).
4. Provenance Phase 1 after Rick's rulings; Step G; #337.

## Ultra (arrives Tue 10/27; dev setup Wed 10/28)
`scripts/install_dev_tools.sh` on a clean Mac (Rick: Xcode, GUI apps, Homebrew, `gh auth login` first). Then TB5 bridge + 10 GbE to the M4. **Before the catalog moves:** `migrate_data.sh --from <M4 TB-bridge IP>` (its catalog checks are uncommitted and need their Codex pass); verify how the catalog identifies a volume moved between Macs (UUID vs device number); `defaults write Rick-Breen.VideoScan CatalogSyncMasterHostname RicksUltra.local` or the Ultra launches as a viewer; recreate the STEAM symlink. Open decision: which fleet roles move to the Ultra (bring a resource plan). The M4 stays untouched as fallback until the Ultra has run green for a week.

## Dates
- 2026-11-01: off-site copy plan due.
- 2026-11-05: cloud session credits expire.

## Open rulings wanted from Rick
0. Charter vs rulings: (a) sampled hash = hint only (rule 6) — DECISIONS line; (b) provenance gate at **ingest** (Charter §2.2) or at **Promote** (10/22 ruling); (c) **Triage** "of questionable value" (Charter §1) vs the 10/11 tab charter — keep, fold into Catalog, or cut?
1. Provenance: the four questions.
2. #327 remainder: Promote/Tidy on a sampled match; "Signed" on a sampled hash.
3. People engines: freeze at Vision + native Find & Tag, or cut further.
4. Archive Angel: keep as recommender, shrink to "ready" badges, or cut.
5. Hallie: detach behind a read model, or stay in-process and shed voice/web/shell until the family viewer is real.
6. Conflict policy for two copies edited differently within one 2 s window (keep both vs latest wins).
