# Stability baseline — 2026-10-14

Rick's ruling (10/14, after a reboot and a day away): establish a new clean
baseline of stability — testbed, metrics, fleet — before any feature work.
This file is the record. Each later baseline supersedes it; keep the shape.

## Verdict

| Host | Commit | Result | Tests | Elapsed | Row |
|---|---|---|---|---|---|
| RicksM5 (M5 Pro, Release) | db00fed4 | **GREEN** | 11,346 pass · 0 fail · 67 skip | 1,281 s | testdriver 2026-10-14T17:03Z |
| RicksM4 (M4 Max, Release) | da66ab27 (pre-fix) | 3 fail, all explained below | 11,348 pass · 3 fail · 62 skip | 1,535 s | testdriver 2026-10-14T17:24Z |
| RicksM1 (M1 Max, Release) | db00fed4 | see "M1" | — | — | pending |

The suite is green on a current tree. Every red seen this week traced to one
of the five causes below; none was a product defect.

## What was red, and why

1. **M4 nightly ran zero tests two nights (10/13, 10/14).** xcodebuild aborted
   in one second: macOS refused the "prevent sleep during UI testing" power
   assertion (`IOPMAssertionCreateWithName` −536870211). A wedged power
   daemon on the box, not code; the same wedge produced a shutdown stall and
   the reboot at 12:16. Cleared by the reboot — the 12:31 run built and ran
   11,413 tests. No code change.
2. **`duplicateDeleteCarriesRicksPlaceOntoKeeper`** (red on every host since
   10/12). Stale expectation: since e883425d (GH #143 T4) a trashed duplicate
   stays as a row marked In the Trash; the sibling sensors were updated in
   that commit, this one was missed. Fixed in db5f37db.
3. **`noStoredStampIsComparedByDeviceNumberOutsideTheOneComparison`** (red
   everywhere, including both sanitizer runs). The sensor found a new raw
   `st_dev` comparison in `CleanupDiskProbe.isMountPresent` (Cleanup v1). It
   is the classic ismount test — two LIVE stats of the same instant, never a
   stored stamp — so it is reviewed and listed with its reason. db5f37db.
4. **`testHallieSurnameRosterOnSharedHundredThousandPersonTree`** (M4 only).
   Release budget 250 ms against a measured 228–262 ms (four nightly runs);
   zero headroom, tripped at 264 ms on a loaded box. Budget → 400 ms with the
   history in the comment; the sibling test already logs this metric without
   asserting it.
5. **Weekly sanitizer runs** (ASan 10/10, TSan 10/11): four perf-budget tests
   could not meet wall-clock / RSS budgets under 2–5× instrumentation. The
   `VIDEOSCAN_SANITIZER` variable WAS reaching the tests; the ASan factor
   (×4) was too small for measured 4.8–5.7×. Factor → ×8; two RSS/60 s tests
   skip under a sanitizer with their reasons; the cache-counter assertions
   moved to an always-on test. Merge 85e86073. Confirm on the next weekly.

## Fleet state

- **M4** — rebooted 12:16; power assertions work again (`pmset -g assertions`).
  Load was 49 at boot (ChatGPT app pinning a core; Spotlight reindexing).
- **M5** — on main, green. Dirt is untracked `.codex/` scratch only. 219 GB free.
- **M1** — was 555 commits behind main (132e5f9e, 10/4) with a dirty
  `Package.resolved`; the nightly does not pull, nobody had synced it since
  10/4. Synced to main 12:46. **Disk 97% full (36 GB free)**, mostly outside
  Xcode caches (DerivedData 5.6 GB, ~/Library/Caches 14 GB) — Rick's data,
  not touched. **GH #319:** the 04:30 nightly's Release compile has been
  running 8+ hours; the build-timeout watchdog published FATAL but its
  `killpg` never reached SWBBuildService / swift-frontend (own process
  groups). Stale processes left for Rick (never pkill).

## Metrics snapshot (nightly 2026-10-14, commit 6fe2b539)

- Complexity baseline 407 (shrunk twice this week); CCN-15 excess 2,106.
  One new offender at the line: `VideoScanModel.prepareDuplicateDeletion`
  CCN 15 / NLOC 81 — Rick's call (split or accept). Four got slightly worse
  (AngelRuleLanguage 27→28, VideoScanApp.body 14→15, ProcessRunner 8→9,
  TriageView.toolbar 7→8).
- Exposure baseline shrunk 2,520 → 2,461 (59 fixed; db00fed4). **365 new
  could-be-private declarations** still open — mostly the Cleanup v1 and
  Archive audit files. Decide: make private (refactor agent, batch by file)
  or `--update-baseline` with a reason.
- Nightly findings #318: 9 CodeQL "sensitive data to log" highs, all under
  existing trackers #252 / #266. Twelve high trackers > 7 days old.
- Hallie replay (M4, 13:24): strict 58/67 failed, advisory 630/803 — the
  replay lane is red independent of the test suite; it did not run 10/13.
  Owner: the Hallie eval ladder, not this baseline.
- Person-recognition readiness 0% (quality holdout not configured) — known.
- Problem files top 3: DeleteDuplicatesJob.swift (132.6), HallieLineageQuestion.swift (41.8), TriageView.swift (41.0).

## Open for Rick

- Purge the ten fully-merged branches (local + origin) and triage the three
  stale unmerged ones (feat/167-catalog-versioning 12 d, test/catalog-focus-control 8 d, wip/r4-untested 7 d).
- Kill the stale 04:30 processes on the M1 (#319) and decide what to free on
  its disk.
- `prepareDuplicateDeletion` CCN 15: split or accept.
- The 365 new over-exposed declarations.
- Spot test Cleanup v1 (never run on the real catalog; dry run 10/12 said
  601 copies / 324 GB).
