# Status — rewritten, never appended

*Updated 2026-10-24. Rick corrects this file; agents read it at session start.*

## This week's theme
**Stability before the Ultra** (Rick, 10/19: "very strong code, stable code by the time I come back with the Ultra on Tuesday"). Feature work is paused except provenance design. No FamilyArchive rescan until Rick says so.

## In flight
- **P0 rescan purge (10/22) — recovered.** 95 archived Masters' rows restored 10/23 14:59 (`p0_restore_95.py`, backup in `App Support/VideoScan/backups/pre-p0-restore-2026-10-23/`). Root cause fixed and merged (`8ddfa80d6`); production-shape sensors merged (`4fe01d31e`); P0 suites in the gauntlet regression stage (`ccf547e50`). **Waiting on Rick:** spot test of the Archive tab (expect 144 Masters). Follow-up GH #366 (P2).
- **Merged 10/24 (`9d28d3c99`), waiting on Rick's Debug spot test:** Archive no-sound mark (#345; the mark shows only after a Full-tier Verify of the archived files) and People tab right-click "Remove from <name>'s Page" / "<name> Isn't in This Video". Codex merge verdicts, 0 findings; related suites 42/42; sensors GREEN 558. Not pushed. Read-only archive sound check 10/23: 141/144 have sound; the 3 silent are the `CapeCodAndMuseum1991` copies (#345). Several archived names carry a doubled date prefix (Rick's to rename via Update…). Follow-ups #368–#371.
- **Nightly 10/24 GREEN:** app 12,271 passed / 0 failed; Core 1,872 / 0. Hallie strict 57/67 (60→58→57; failing cases churn night to night).
- **M4 `powerd` wedge recurred 10/24** (IOPM assertion −536870211; `caffeinate -i -t 1` fails): `sudo killall powerd` cleared it without a reboot.
- **`test/gauntlet-prodshape`** (locked worktree): gauntlet Runner takes a read-only `.backup` of the live catalog (`VIDEOSCAN_LIVE_CATALOG_COPY`). Rick approved the design; not yet merged. Leave it to its owner session.
- **Provenance** (design under review): `docs/design/provenance_lightweight_2026_10_22.md` + `docs/research/provenance_deep_dive_2026-10-23.md`. Phase 0 harvester ran read-only (143 Masters + July VHS batch). Needs Rick's four answers (manifest v4 vs `Provenance.csv`; role list; hard or soft Promote gate; July device chain) before Phase 1 (schema v13, Needs-provenance filter, Provenance sheet).
- **Step G (JSON gone):** the read path is being removed; `CatalogStore.swift` and Core `Import/` were still compiled on 10/23. Finish or schedule. Cutover-audit P1s still open as of the last docs: #338 (near-full high-water), #339 (quarantine door), the stale-JSON-reader item.
- **VideoScanModel split (#337, P1):** plan and estimate first (architecture escalation); slices 0–1 landed (PreviewService). No new `extension VideoScanModel`.

## Next (in order)
1. Rick's Archive-tab spot test → close the P0 thread.
2. Merge `test/gauntlet-prodshape`; confirm the nightly runs the P0 suites and the catalog tests.
3. Provenance Phase 1 after Rick's four rulings.
4. Step G to completion (remove `CatalogStore`, Core `Import/`, `JSONCatalogRepository`; keep the frozen JSON as history).
5. #337 plan → Rick's go → slices in worktrees at night.

## Ultra (arrives Tue 10/27; dev setup Wed 10/28)
`scripts/install_dev_tools.sh` on a clean Mac (Rick: Xcode, GUI apps, Homebrew, `gh auth login` first). Then TB5 bridge + 10 GbE to the M4. **Before the catalog moves:** `migrate_data.sh --from <M4 TB-bridge IP>` (its catalog checks are uncommitted and need their Codex pass); verify how the catalog identifies a volume moved between Macs (UUID vs device number); `defaults write Rick-Breen.VideoScan CatalogSyncMasterHostname RicksUltra.local` or the Ultra launches as a viewer; recreate the STEAM symlink. Open decision: which fleet roles move to the Ultra (bring a resource plan). The M4 stays untouched as fallback until the Ultra has run green for a week.

## Dates
- 2026-11-01: off-site copy plan due.
- 2026-11-05: cloud session credits expire.

## Open rulings wanted from Rick
0. Two places where the Charter (10/23) and recent rulings differ: (a) provenance gate at **ingest** (Charter §2.2) or at **Promote** (10/22 ruling, provenance design); (b) **Triage** "of questionable value" (Charter §1) vs the 10/11 tab charter making it the side-lane lens and the only bulk-removal door — keep, fold into Catalog, or cut?
1. Provenance: the four questions above.
2. #327 remainder: Promote/Tidy on a sampled match; "Signed" on a sampled hash.
3. People engines: freeze at Vision + native Find & Tag, or cut further (POI search across footage is no longer the strategy).
4. Archive Angel: keep as recommender, shrink to "ready" badges, or cut.
5. Hallie: detach behind a read model, or stay in-process and shed voice/web/shell until the family viewer is real.
6. Conflict policy for two copies edited differently within one 2 s window (keep both vs latest wins).
