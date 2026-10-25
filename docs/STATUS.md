# Status — rewritten, never appended

*Updated 2026-10-25 (night). Rick corrects this file; agents read it at session start.*

## This week's theme
**Stability before the Ultra** (Rick, 10/19) — and **Swift 6 everywhere is done** (Rick's ruling 10/25, carried out the same day: `docs/design/swift6_migration_2026_10_25.md`, #376). Feature work is paused except provenance design. No FamilyArchive rescan until Rick says so.

## Swift 6 — end state (the session-start hook prints the measured line)
- **All eight stages merged and pushed 10/25.** 460 warnings → 1 (the mlx-swift `setErrorHandler` deprecation, documented in `Shared/MLXSafety.swift`; the figure reads 99 % until mlx-swift ships a replacement). **Core and the app target are in Swift 6 language mode**; `SWIFT_STRICT_CONCURRENCY` is gone (implicit). The app's 1,128 files compiled with zero errors on the first Swift 6 build — stages 3–7 had cleared every would-be error; the flip's errors were all in the test targets and were fixed per §6a.
- **Every slice:** fresh-eyes reviewer (two contract drifts and one real data bug caught and fixed red/green), Codex on every rule-10 file (all *merge*, 0 findings), related suites with counts, sensors GREEN, baseline lowered only from clean logs. Opt-outs added carry a `// Swift 6:` invariant (`grep -rn "// Swift 6:" VideoScan/`); net escape-hatch count fell (slice B −10).
- **Not yet proven:** the full 12k app suite and the gauntlet on the flipped tree — the 10/26 02:00 nightly on the fleet does that. If it is red, the flip stays (fix forward, red/green); do not revert the mode.
- **The floor stays:** `scripts/warning_ratchet.py` in the sensor lane (per file × category; nothing may rise; baseline now 1). Stage 2's nightly analysis lane (`scripts/nightly_analysis_lane.sh`: ratchet verify, escape-hatch census, Periphery, `-strict-memory-safety`, TSan/ASan+UBSan by weekday) is merged but **not installed** — Rick runs `bash scripts/install_analysis_lane.sh` on the M4 when ready (rota slot 04:30).
- **Retire the design doc** to `docs/archive/` after the 10/26 nightly is green.

## In flight (other)
- **#383 editor caches (10/25):** scan skips iMovie/FCP render caches unconditionally; Tidy Catalog sets aside the 545 existing rows. Waiting on Rick: run Tidy Catalog…, confirm, then turn Skip Small Files back on in Scan Options.
- **P0 rescan purge (10/22) — recovered;** the 10/24 LaCieWorkspace rescan left all 144 FamilyArchive Masters intact. **Waiting on Rick:** Archive-tab spot test (expect 144 Masters). Follow-up #366 (P2).
- **#375 merged 10/25** (Codex branch, gated here; + engine fix: a rejection keeps the record's own spelling). **Waiting on Rick's spot test:** Catalog → Organize shows the nickname (Timmy); unchecking leaves a correctly-cased strikethrough in the Inspector.
- **Merged 10/24, waiting on Rick's Debug spot test:** Archive no-sound mark (#345), People tab row removal. Follow-ups #368–#371.
- **Other spot-test targets from 10/25 slices:** Catalog People column and Relocate summary sheet text; filmstrip / Find Person seeking; People tab first load; Family Tree recompile/pull (Sendable store, same writers).
- **Process bugs fixed 10/25:** the sensor-lane GREEN stamp had never been written and then never matched a commit — no push to main had passed the hook since 10/23; fixed red/green (`scripts/sensor_lane_stamp.sh`). Main is pushed through `17485b1fe`…
- **Nightly 10/24 GREEN:** app 12,271 / 0; Core 1,872 / 0. Hallie strict 57/67.
- **Issues opened 10/25:** #377 stale gauntlet manifest entries · #378 two People tests assert a raw 500 ms budget (every weekly sanitizer run reads tests-failed) · #379 CI publishes `periphery_aggressive: 0` vs 1,440 locally · #380 HallieWebServer synchronous 1 MiB reads on the server queue · #381 HallieQueryBench residency probe fails on the interactive M4 (pre-existing, machine-dependent).
- **`test/gauntlet-prodshape`** (locked worktree): leave it to its owner session.
- **Provenance** (design under review): needs Rick's four answers before Phase 1.
- **Step G (JSON gone):** finish or schedule. Cutover-audit P1s: #338, #339, the stale-JSON-reader item.
- **VideoScanModel split (#337, P1):** plan → Rick's go → slices.

## Next (in order)
1. 10/26 morning: read the nightly (full suite + gauntlet on Swift 6). Green → retire the design doc, close #376. Red → fix forward with red/green; the mode stays.
2. Rick: Archive-tab and #375 spot tests; the two Charter rulings (sampled hash = hint only; provenance gate at ingest or Promote); commit the Charter edits (+ §3.8 Development Modes); install the analysis lane when ready.
3. #378 (two-line fix; unblocks the sanitizer lanes); #377; #381.
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
