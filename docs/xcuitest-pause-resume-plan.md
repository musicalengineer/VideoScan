# XCUITest Plan — Pause/Quit/Restart/Resume canary

Goal: end-to-end UI test that drives real button clicks through SwiftUI to
prove the pause-survives-restart bug (fixed in 59c71f9 + 78939ac) stays
fixed at the UI layer, not just the model layer.

## Scope

This is the *first* XCUITest beyond the existing Catalog/Combine ones to
exercise the People (Person Finder) tab. Keep additions minimal — only
what this single canary needs. Future tests can opt-in to the same
storage-isolation primitive without re-plumbing.

## Files touched

| File | Change |
|---|---|
| `VideoScan/VideoScan/UITestStorageOverride.swift` | NEW — single helper that redirects POI/scan_jobs/catalog/UserDefaults to a per-process tmp dir when `--ui-test-fresh-storage` is on argv. Seeds one synthetic POI so a job can be created without photo I/O. |
| `VideoScan/VideoScan/main.swift` | Detect `--ui-test-fresh-storage` BEFORE `VideoScanApp.main()` runs. Activate the override. |
| `VideoScan/VideoScan/POIStorage.swift` | Honor a one-shot directory override (set by `UITestStorageOverride.activate()`). Production path unchanged. |
| `VideoScan/VideoScan/ScanJobsStorage.swift` | Same override hook. Already supports tmp-dir under XCTest; generalize the gate. |
| `VideoScan/VideoScan/CatalogStore.swift` | Same override hook on the `init()` no-arg path. Internal `init(directory:)` already exists. |
| `VideoScan/VideoScan/PersonFinderView.swift` | Add `.accessibilityIdentifier("personFinder.familyButton.<name>")` on each Family gallery card so the test can click "TestPerson". Add `.accessibilityIdentifier("personFinder.newSearchMenu")` on the "New Search…" menu, and matching IDs on its items. |
| `VideoScan/VideoScan/ScanJobRow.swift` | Add `.accessibilityIdentifier("scanJob.pause.<jobID>")` / `.resume` / `.status` on the collapsed AND expanded action buttons + status badge. Use the job's UUID short prefix so multiple rows are unambiguous. Also add `scanJob.status.<id>` on the Paused text label. |
| `VideoScan/VideoScanUITests/PauseRestartUITests.swift` | NEW — the canary test. |
| `docs/xcuitest-pause-resume-plan.md` | This file. |

## Launch-flag wiring

`--ui-test-fresh-storage` on argv (set via `XCUIApplication.launchArguments`).
Detection is intentionally separate from `isRunningTests`: under XCTest the
host process is already redirected by the existing `isRunningTests` checks,
but XCUITest tests run the *app* binary, which is NOT a test host — none of
the existing redirects fire. The new flag is the bridge.

Pattern, in `main.swift`:

```swift
if ProcessInfo.processInfo.arguments.contains("--ui-test-fresh-storage") {
    UITestStorageOverride.activate()
}
```

`UITestStorageOverride.activate()`:
1. Sets a `static var directoryOverride: URL?` on POIStorage, ScanJobsStorage, CatalogStore (each independently — already a static-var pattern). All three then prefer the override over their normal Application Support resolution.
2. Creates `/tmp/VideoScan-UITest-<pid>-<short uuid>/` as the override root.
3. Sets a synthetic POI on disk so the People gallery is non-empty.
4. Sets `UserDefaults.standard.set(0, forKey: "selectedTab")` so the People tab is the default on first launch (avoids relying on argv `-selectedTab` parsing).

## Accessibility identifiers added

Format follows the existing `tab.<Label>` / `combinePairSheet.<element>`
convention seen in CombineWorkflowUITests.

Minimum set for this canary:

| ID | Element |
|---|---|
| `tab.People` | (already exists) People tab button |
| `personFinder.familyCard.<name>` | Each Family-gallery person card button — sanitized name only |
| `personFinder.newSearchMenu` | The "New Search…" menu button |
| `personFinder.newSearchItem.<name>` | The submenu item per profile |
| `scanJob.pauseResume.<jobID>` | The Pause/Resume button (toggles label by status) — same ID on collapsed and expanded rows. SwiftUI Menu items inside `Menu { }` won't propagate IDs to NSMenuItems per CombineWorkflowUITests history, but a standalone Button does. |
| `scanJob.status.<jobID>` | The "Paused" / "Done" status badge Text |
| `scanJob.row.<jobID>` | The row container — for finding & clicking to expand |
| `scanJob.startButton.<jobID>` | The "Start" / play button in idle state |

`<jobID>` = first 8 chars of `job.id.uuidString.lowercased()`. Stable across
relaunch because the UUID round-trips through the PersistedJobDescriptor.

## What the canary test asserts

```
1. Launch app with --ui-test-fresh-storage.
2. People tab is already selected. Family gallery shows one card: "TestPerson".
3. Click personFinder.newSearchMenu, click personFinder.newSearchItem.TestPerson.
4. A ScanJobRow appears in idle state. Type a search path into the volume picker
   — actually no, we'll set it via the launch override (the synthetic POI's
   `referencePath` and the row's initial `searchPath` are both seeded so the row
   is "Start-ready" without driving the volume picker, which is an NSOpenPanel
   that XCUITest can't easily click).
5. Click scanJob.startButton.<id>. Status transitions to .scanning (or
   .failed/.done very quickly if no videos found — which is fine, we
   only need a status that pauseJob can transition from).

   Wait — pauseJob requires .scanning. If the scan completes too fast
   (empty dir → 0 videos → .done in <100ms), we never get a chance to
   pause. Solution: seed the searchPath with a 1-video directory we
   pre-create in the override, where the video is bogus but ffprobe
   takes long enough to give us a pause window. Even simpler: skip
   the start phase entirely and synthetically push the job to
   .scanning via a launch-flag testing hook in PersonFinderModel
   that exposes `pauseFirstJobForUITest()`. Decided: do the scan and
   pause for real — it's a more honest test, but use a non-existent
   /tmp/empty-test-volume so the scan immediately fails with .failed.
   We then call pauseJob via UI on a .scanning job by ensuring the
   job stays in .scanning. The pauseJob guard `job.status == .scanning`
   is the constraint.

   Pivot: skip the real scan. Use the synthetic POI + searchPath seed
   so the row is in idle. Click the Pause button only AFTER manually
   triggering the in-process scan-state-but-no-task path. Since we
   can't easily fake .scanning without touching code, we'll instead
   wire a tiny test-hook on PersonFinderModel:
   `setUITestForceScanningOnFirstJob()` activated only when the
   launch flag is on. The hook sets the first job's status to
   .scanning + creates an empty pauseGate so pauseJob's gate.pause()
   no-ops cleanly. Status flips to .paused, descriptor persists.

6. Click scanJob.pauseResume.<id>. Status flips to "Paused".
7. Terminate app.
8. Relaunch with --ui-test-fresh-storage (same tmp dir — we pass
   it explicitly via env var so override picks the SAME dir, not
   a new one).
9. People tab. Same row appears.
10. ASSERT: scanJob.status.<id>.label == "Paused" (NOT "Done").
11. ASSERT: scanJob.pauseResume.<id> exists and is hittable (it's
    a single button that toggles its image — the assertion is
    really "the row is in paused-actionable state").
12. Click scanJob.pauseResume.<id>. The job's wasRestoredFromDisk
    branch in resumeJob() routes to startJob, which hits the
    reachability guard on the unreachable searchPath, transitions
    to .failed.
13. ASSERT: status changed away from "Paused" within 5s.
```

## M1 execution strategy

- SSH into ricksm1.local; cwd `~/dev/VideoScan`.
- `git fetch` + `git checkout feature/xcuitest-pause-resume`.
- Wrapper script writes:
  ```
  xcodebuild test \
    -project VideoScan/VideoScan.xcodeproj \
    -scheme VideoScan \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath /tmp/m1-uitest-dd \
    -only-testing:VideoScanUITests/PauseRestartUITests \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/m1-uitest.log
  ```
- LaunchAgent (per yesterday's pattern): `RunAtLoad=true`, `KeepAlive=false`,
  Label `com.rickb.videoscan-uitest`. ProgramArguments points at the wrapper.
  `launchctl bootstrap gui/$(id -u) <plist>`; tail `/tmp/m1-uitest.log` until
  the test summary line appears.

## Red→green→red→green prove-out

Per `feedback_tdd_verification`:
1. **green-1**: branch HEAD has the fix. Run, expect pass.
2. **red-1**: temporarily revert the two-line fix in
   `PersonFinderModel+JobLifecycle.makeJob` (set `job.status = .done`
   unconditionally) and in `resumeJob` (drop the
   `job.status = .idle` reset). Don't `git revert` — just edit the
   lines back to their pre-fix shape. Re-run, expect both assertions
   in step 10–13 to fail.
3. **green-2**: restore the fix lines verbatim. Re-run, expect pass.
4. Document each cycle's commit SHA + xcresult summary in the PR
   description.

## VideoScanUITests-Runner early-exit triage (parallel investigation)

Check `~/Library/Logs/DiagnosticReports/` on M4 + M1 for
`VideoScanUITests-Runner-*.ips`. If the pattern is consistent
(e.g. signing related, missing entitlement, AppKit pre-main),
fix it. Otherwise capture the top-of-stack from the most recent
crash report and document in the PR for a follow-up issue.

## Out of scope (deliberately)

- Driving the NSOpenPanel for the volume picker (synthetic path instead).
- Driving the reference-photo picker (synthetic POI on disk instead).
- Covering compilation / clip extraction (the bug we're protecting against
  is purely the pause/resume state survival).
- Adding accessibility IDs to controls the canary doesn't touch.
