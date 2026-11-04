# Status — rewritten, never appended

*Updated 2026-11-04 (Wednesday, overnight). Rick corrects this file; agents read it at session start.*

## Read first (five minutes)
0. **Night 11/03 — the checklist audit is merged (main `f393a3ba`).** Rick: "use the checklist on our most recent changes … I'm leaving you and codex to have at it." Codex reviewed `ffdb3018` (BG helper, menu bar, Catalog/Content split, count fix, gate). Verdict was fix, with **7 findings, all real and all fixed**, each red first. The closing Codex pass on the fixes took 9 rounds and ended **merge, 0 findings**. The reviewer agent added 6 red tests, and all of them are green now.
   - **F1 (P0) A viewer counted the wrong catalog.** A viewer now counts nothing: its job line says the master runs content analysis, and Catalog Database Info reads `viewer-catalog/catalog.sqlite` ("the master's synced copy"). There is one rule, `CatalogAuthority.databaseURL(role:opened:catalogFile:)`. "Is viewer" now comes from one source, the sync role.
   - **F2 (P0) "Analyzing N of M" showed while only the era job ran.** The era job is not one of the counted analyzers, so Content never lights blue for it. It gets its own line: "Machine era: N of M files (VideoScan Background — state)". A paused job or a paused dossier batch no longer lights "Analyzing" either.
   - **F3 (P0) The menu bar said "running" while the job was waiting for you to step away.** Jobs now have a `waiting` state: "waiting — you're at the Mac (the model loads when you step away)". It has its own glyph, an outline lens with a dot. The protocol stays v1, and an older payload still decodes.
   - **F4 (P1) OFF was unreachable from a disabled checkbox.** The box is disabled only when it is OFF and ON is refused. The "not registered" fix now names the Release build.
   - **F5 (P2) The menu's own status poll kept the helper from ever idle-exiting.** Reading status is no longer activity; only an XPC client call counts.
   - **F6 (P2) Logging.** Every problem the Settings lines, Catalog Status (`[catalog-status]`) and Database Info can show is logged when it appears, changes and clears, never per poll. Count failures name the catalog path. The helper logs when "Open VideoScan" is disabled.
   - **F7 (P2)** The count test runs against a real schema-current catalog.sqlite.
   - **#417 fixed:** the P0 truth test expects "silent (measured)". Lanes on the merged tree: sensor lane GREEN 649 (my own run on the tip; the app half printed 628 of 629, the same overwritten-line glitch as 11/02 — 0 failed) · Core touched 75 / 0 · App touched suites 112 / 0 · gauntlet inventory 0 errors.
1. **Landed 11/03 (day), on main:**
   - **Signing (`18eafce6`):** the app and helper are signed with Rick's Apple Development team (V9SVEQF26M), so a rebuild no longer gets the helper killed at spawn (EX_CONFIG 78, stale LWCR). This was proven on a toy agent.
   - **Helper scheme and icon (`09c9f821`):** a "VideoScan Background" scheme builds the helper alone, with a teal icon.
   - **Release-only gate (`50b7fe05`):** only the Release build on the master registers the helper.
   - **Menu bar item (`3c5d5e6f`):** a template glyph that shows what the helper is doing, with Pause/Resume and Open VideoScan. The helper is `.accessory`, so it has no Dock icon of its own.
   - **Status split (`9926898d`):** two indicators. Catalog is Synced / Stale / Unhealthy / Unknown. Content is "Up to date", "N left to analyze" or "Analyzing N of M".
   - **Count fix (`28a14a5b`):** the count reads catalog.sqlite, not catalog.json.
   - **Version 5.4.**
   - **The checklist** (PROCESS §2a, CLAUDE.md rule 9).
2. **#416 is closed. Sound prints are no longer recomputed every run.**
   - **Part 1:** stamps key on the row's stored digest, archive fixity included.
   - **Part 2, schema B (Rick's option B):** migration **v15 `sound_attempts`** (schema 14 → 15). A file that hears too little or will not decode is tried 3 times per engine, then given up, and coverage counts it as covered. Codex cycles #217–#219 were all fixed.
   - **Backup before v15** (integrity ok, 23,060 files, 6,360 prints): `~/Library/Application Support/VideoScan/backups/pre-v15-sound-attempts-2026-11-03/catalog.sqlite`. The app migrates on its next launch.
3. **Helper on the Ultra:** the helper registered at 14:55 and is running the era job, 523 files, overnight in trickle. It waits while you are at the keyboard.

## Spot tests for Rick (Release once to install the helper, then Debug)
- **Menu bar** (Release helper running): with you at the Mac, the icon is an outline lens with a dot and the job reads "waiting — you're at the Mac…". Step away and it turns solid ("running"). Pause shows bars.
- **Main window strip:** Content stays grey "N left to analyze" while only the era job runs; it should never be blue for era. Click it and Content Analysis shows the "Machine era: N of M files" line.
- **Settings ▸ Background in a Debug build:** the checkbox is still enabled while ON, and unticking it logs and unregisters.
  - **Watch for:** the Debug app unregistering the *Debug* copy may not unregister the Release one. If it fails, the line says so and the log has the words.
  - Re-tick from Release afterwards.
- **Log check, no screenshots:** `~/Library/Logs/VideoScan/videoscan.log` shows one `background service:` line per problem change and `[catalog-status]` lines only when a colour or cause changes.

## Waiting on Rick
- **#415, the rebuild test:** rebuild Release with the helper running. It should keep running with no re-tick (team signing). If it does, close #415.
- **Restart the helper with `launchctl kickstart -k`** for that test, or by quit-and-reopen: your call, since it kills a process.
- **M4 Ollama:** set `OLLAMA_HOST` so the Ultra can use it over TB5. This needs its Ollama restarted.
- **Menu bar icon when the helper is idle:** hide it, or keep it? The default is to keep it; the helper exits after 10 idle minutes anyway, and the icon goes with it.
- **The catalog lane is RED by its own rule on 7 `withKnownIssue` tests** (none failed; the gauntlet classifies the same way). They are not from this work:
  - `CatalogQuitCornerTests` case 3 ×2 (#356);
  - `CatalogOpenCornerTests` case 9 (#358);
  - four disk-full/witness pins (#338/#357 family).
  - Options: fix those bugs, or rule that a tracked known issue is amber, not red (already listed: "gauntlet runner policy").
- Carried over: #327's two rulings; #332 (play two or three archived titles); the cleanup proposal; the other older defaults in the 11/02 list (git `bb39167a:docs/STATUS.md`).

## Next
1. #418: the two P2s from schema B.
2. Helper throughput while you work, and jobs on the M4 over TB5 (BACKLOG 11/03).
3. Catalog Status "Fix…" button (Disk Utility shape); the first verb removes an event member whose row is gone.
4. #413 (P1): dossier propagation groups copies by partialMD5.
5. #412, #408, Hallie shell on a viewer (BACKLOG H′); DV datecode bound; prompt r4 stays rejected (r3 seated).

## In flight / cleanup
- Worktrees to prune after Rick's word (move to `.trash/`):
  - from today: night-1103, review-1103, fix-416, status-split, bg-owner-lock;
  - plus the 11/02 list (git `bb39167a:docs/STATUS.md`).
- Open: #384 · #389 · #377 · #379 · #380 · #381 · #338 · #339 · #337 (VideoScanModel split).

## Dates
- 2026-11-05: cloud session credits expire. Mid-November: grade A in every module. 2026-12 soft / 2027-01 target: Public view link for family (Charter §5).
