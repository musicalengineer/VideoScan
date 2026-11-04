# Codex review — Checklist audit 11/03 — closing

- Range: `ffdb3018..9f0c5ac2`
- Credits spent: unavailable
- Tokens: 125886
- Finding count: 4
- Verdict: fix — four scoped invariants remain incomplete.
- Run: 2026-11-04T02:34:04Z (cycle #223, tools/codex_review.py)

## Codex answer

Reviewed `ffdb3018..9f0c5ac2`. Four invariants still fail:

1. **P0 · TRUE · invariant 2 — Paused local analysis still shows “Analyzing.”**  
   [CatalogFreshnessSnapshot.swift:410](/Users/rickb/dev/VideoScan-wt/night-1103/VideoScan/VideoScan/Analyze/CatalogFreshnessSnapshot.swift:410) checks `state.isActive` without `isPaused`. Start Full Hashes, pause it, and leave no other analyzer running: `FullHashBackfillJob.pause()` leaves `.running`, so Content continues claiming progress indefinitely. Regression: a paused Full Hashes job must not make `contentIsWorking` true.

2. **P0 · TRUE · invariant 3 — Pausing a deferred job fills the lens.**  
   [BackgroundMenuPresentation.swift:42](/Users/rickb/dev/VideoScan-wt/night-1103/VideoScan/VideoScanCore/Sources/VideoScanCore/Background/BackgroundMenuPresentation.swift:42) treats every `.pausing` job as moving. After a unit defers, press Pause during the 30-second retry sleep: the supervisor changes state to `.pausing`, suppresses the waiting snapshot, and the menu immediately displays `.working` although no unit runs. Regression: pause the existing deferring fixture before its retry; require the icon to remain unfilled.

3. **P2 · TRUE · invariant 1 — An existing helper job overrides the viewer explanation.**  
   [BackgroundServiceStore.swift:514](/Users/rickb/dev/VideoScan-wt/night-1103/VideoScan/VideoScan/App/BackgroundServiceStore.swift:514) returns the local era job before checking `viewer`. Relaunch a former master as a viewer while its registered helper retains an era job: Settings shows local job counts instead of saying the master analyzes. Regression: extend `viewerCountsNothing` with an era job in the status reply and retain the `viewerJob` assertion.

4. **P2 · LOGGING · invariant 6 — Additional Database causes can appear and clear silently.**  
   [CatalogStatusLines.swift:513](/Users/rickb/dev/VideoScan-wt/night-1103/VideoScan/VideoScan/Analyze/CatalogStatusLines.swift:513) compares only state and headline words. With Database already red from an integrity failure, a sound-store failure is placed in `detail`; its appearance, changed reason and recovery produce no transition log. Regression: hold the integrity failure constant while changing `soundStoreProblem` through nil → failure → nil; require appearance and clearance logs.

Remaining scoped files: **read, no findings**. Invariants 4, 5 and 7, and the GH #417 wording correction, pass code inspection.

The proposed regressions were not executed: the scoped Swift test attempt failed before running tests with `permissionDenied` under the read-only sandbox. Supplied green counts were not independently reproduced. Concurrent staged changes and the manifest conflict are excluded from this verdict.

Credits spent: unavailable | Finding count: 4  
Verdict: fix — four scoped invariants remain incomplete.

## Brief

# Codex brief — closing pass on "Checklist audit 11/03 (BG + status split + count)"

Range: ffdb3018..HEAD on fix/night-1103-checklist (3 commits). Your cycle #220 found 7 findings; this branch claims to fix them plus a fresh-eyes reviewer's adds. Verify each invariant holds in the code at HEAD; report a finding only where one still fails (file:line, scenario, severity, checklist item).

The 7 invariants:
1. TRUE (data): the database a count or Catalog Database Info reads is the one the ROLE displays — master: cutover-opened else catalog.sqlite beside catalog.json; viewer: viewer-catalog/catalog.sqlite. ONE function (CatalogAuthority.databaseURL(role:opened:catalogFile:)) used by both callers. A viewer attempts no local era count; its job line says the master analyzes. "Viewer" is the sync role (catalogSync.mode / CatalogSync.launchMode), never catalogModel.isReadOnly.
2. TRUE: no surface shows progress the running work cannot move. Content "Analyzing N of M" only when a counted analyzer runs or the helper RUNS (not queued/paused/waiting) a job of a kind in BackgroundServiceActivity.feedsCountedAnalyzers (empty today). The era job is its own detail line ("Machine era: N of M files (VideoScan Background — <state>)").
3. TRUE: a job whose units defer is shown "waiting — <why>" with the waiting glyph (not the filled lens) in the menu bar and Settings; a queued job does not fill the lens. JobProgressSnapshot.waiting is additive (older payload decodes; schema stays 1).
4. WORKFLOW: the checkbox is disabled only when OFF and turning ON is refused; ON in Debug or on a viewer can be unchecked (unregister called). The "not registered" Fix names a verb this build can do.
5. PERFORMANCE: JobSupervisor.status() does not count as activity (menu bar's 5 s read); XPC status from the app does (noteClientActivity) — idle exit works with VideoScan closed.
6. LOGGING: every Settings ▸ Background problem (launchd states, not answering, gate refusal, count failure/recovery with path) and every Catalog Status line colour/cause change and every Catalog Database Info "unknown —" fact is logged once on appear/change/clear, never per poll/recompute. BackgroundCatalogAccess open refusal names the path.
7. TESTED: the count test uses a real schema-current catalog.sqlite with a known eligible count and requires .success through productionCountWork (master fallback, master opened-elsewhere, viewer no-count, DB Info viewer vs master).

Also: P0TruthRegressionTests now expects "Video+Audio · silent (measured)" (GH #417, Rick's 11/02 ruling).

Evidence: sensor lane GREEN (649 tests) at HEAD; touched app suites 104/104; Core background suites 74/74; gauntlet inventory --validate 0 errors.
Output contract: one finding per still-failing invariant with file:line, scenario, P0–P3, item. End with `Credits spent: … | Finding count: N` and `Verdict: merge|fix|block`. Stay within the changed files plus direct call sites.

---

# Codex review — Checklist audit 11/03 — closing

- Range: `ffdb3018..8734f8ae`
- Credits spent: unavailable
- Tokens: 133859
- Finding count: 2
- Verdict: fix — paused dossier progress and simultaneous Database-cause logging remain incorrect.
- Run: 2026-11-04T02:47:21Z (cycle #224, tools/codex_review.py)

## Codex answer

Reviewed first-parent changes in `ffdb3018..8734f8ae`, excluding main’s changes. The four previous examples are fixed; two invariants remain incomplete.

1. **P0 · TRUE · invariant 2 — Paused dossier analysis still claims “Analyzing.”**  
   [CatalogFreshnessSnapshot.swift:400](/Users/rickb/dev/VideoScan-wt/night-1103/VideoScan/VideoScan/Analyze/CatalogFreshnessSnapshot.swift:400) observes only `statusIsActive`, ignoring `DossierDashboardState.paused`. Start dossier analysis, pause it, and let in-flight work drain with files remaining. `CaptionOrchestrator.pause()` leaves the status active, so Content indefinitely claims “Analyzing N of M” with nothing moving.  
   **Regression:** feed `observeDossier` an active snapshot, then set `paused = true` with empty active lanes; require Content to return to “N left to analyze.”

2. **P2 · LOGGING · invariant 6 — Secondary Database causes still disappear from logs when the headline also changes.**  
   [CatalogStatusLines.swift:507](/Users/rickb/dev/VideoScan-wt/night-1103/VideoScan/VideoScan/Analyze/CatalogStatusLines.swift:507) logs only headline words on initial appearance or colour/headline changes. Detail differences are checked exclusively in the final `else if`. Launch with both a failed integrity check and an unreadable sound sidecar: the UI shows both, but the log omits the sidecar failure. Subsequent identical publications cannot recover it.  
   **Regression:** first publish integrity failure plus `soundStoreProblem`; require the log to contain both causes. Repeat starting from healthy facts, introducing both failures together.

Remaining scoped files: **read, no findings**. Invariants 1, 3, 4, 5 and 7, and GH #417’s wording, pass code inspection. Investigation stayed within changed files and direct dependencies.

The targeted Core test attempt failed before executing tests with sandbox `permissionDenied`. Proposed regressions were not executed; supplied green counts were not independently reproduced.

Credits spent: unavailable | Finding count: 2  
Verdict: fix — paused dossier progress and simultaneous Database-cause logging remain incorrect.

## Brief

# Codex brief — closing pass on "Checklist audit 11/03 (BG + status split + count)"

Range: ffdb3018..HEAD on fix/night-1103-checklist. HEAD includes a merge of origin/main (schema-B sound_attempts, 3028e9c0) — main's own changes are out of scope; review this branch's commits (first parent). Your previous closing pass (cycle on ffdb3018..9f0c5ac2) returned 4 findings — paused MFO job lit Analyzing, pausing waiter filled the lens, viewer line lost to a leftover era job, a second Database cause unlogged — fixed in the last commit; verify them too. Your cycle #220 found 7 findings; this branch claims to fix them plus a fresh-eyes reviewer's adds. Verify each invariant holds in the code at HEAD; report a finding only where one still fails (file:line, scenario, severity, checklist item).

The 7 invariants:
1. TRUE (data): the database a count or Catalog Database Info reads is the one the ROLE displays — master: cutover-opened else catalog.sqlite beside catalog.json; viewer: viewer-catalog/catalog.sqlite. ONE function (CatalogAuthority.databaseURL(role:opened:catalogFile:)) used by both callers. A viewer attempts no local era count; its job line says the master analyzes. "Viewer" is the sync role (catalogSync.mode / CatalogSync.launchMode), never catalogModel.isReadOnly.
2. TRUE: no surface shows progress the running work cannot move. Content "Analyzing N of M" only when a counted analyzer runs or the helper RUNS (not queued/paused/waiting) a job of a kind in BackgroundServiceActivity.feedsCountedAnalyzers (empty today). The era job is its own detail line ("Machine era: N of M files (VideoScan Background — <state>)").
3. TRUE: a job whose units defer is shown "waiting — <why>" with the waiting glyph (not the filled lens) in the menu bar and Settings; a queued job does not fill the lens. JobProgressSnapshot.waiting is additive (older payload decodes; schema stays 1).
4. WORKFLOW: the checkbox is disabled only when OFF and turning ON is refused; ON in Debug or on a viewer can be unchecked (unregister called). The "not registered" Fix names a verb this build can do.
5. PERFORMANCE: JobSupervisor.status() does not count as activity (menu bar's 5 s read); XPC status from the app does (noteClientActivity) — idle exit works with VideoScan closed.
6. LOGGING: every Settings ▸ Background problem (launchd states, not answering, gate refusal, count failure/recovery with path) and every Catalog Status line colour/cause change and every Catalog Database Info "unknown —" fact is logged once on appear/change/clear, never per poll/recompute. BackgroundCatalogAccess open refusal names the path.
7. TESTED: the count test uses a real schema-current catalog.sqlite with a known eligible count and requires .success through productionCountWork (master fallback, master opened-elsewhere, viewer no-count, DB Info viewer vs master).

Also: P0TruthRegressionTests now expects "Video+Audio · silent (measured)" (GH #417, Rick's 11/02 ruling).

Evidence: sensor lane GREEN (649 tests) at HEAD; touched app suites 106/106; Core background suites 75/75; gauntlet inventory --validate 0 errors.
Output contract: one finding per still-failing invariant with file:line, scenario, P0–P3, item. End with `Credits spent: … | Finding count: N` and `Verdict: merge|fix|block`. Stay within the changed files plus direct call sites.

---

# Codex review — Checklist audit 11/03 — closing

- Range: `ffdb3018..d5f466ba`
- Credits spent: unavailable
- Tokens: 110245
- Finding count: 1
- Verdict: fix — invariant 6 still suppresses genuine cause changes and logs some count-only changes.
- Run: 2026-11-04T02:54:22Z (cycle #225, tools/codex_review.py)

## Codex answer

1. **P2 — LOGGING, invariant 6:** [CatalogStatusLines.swift:499](/Users/rickb/dev/VideoScan-wt/night-1103/VideoScan/VideoScan/Analyze/CatalogStatusLines.swift:499) removes every digit when comparing causes, including digits in drive names and error details. Reproduce with an unchanged audit while `/Volumes/X8` reconnects and `/Volumes/X9` becomes unavailable, both holding 30 files. The Files line changes which drive needs connecting, but the normalized strings match, so no transition is logged. Conversely, `Analyzing 999 of 2,000 files` → `1,000 of 2,000` logs a false cause change because the comma survives. Compare structured causes, excluding only count/age fields. A regression should require one transition for the drive change and none for the count change.

All six previously reported scenarios: fixes verified in code and regression coverage read. Remaining scoped changes for invariants 1–5 and 7, plus GH #417’s `silent (measured)` expectation: **read, no findings**. Main’s merged changes were excluded.

Swift test execution stopped before running tests: the read-only sandbox denied compiler/cache access. Supplied green counts were not independently reproduced. The normalization counterexamples were confirmed with a read-only Python reproduction; no files changed.

Credits spent: unavailable | Finding count: 1  
Verdict: fix — invariant 6 still suppresses genuine cause changes and logs some count-only changes.

## Brief

# Codex brief — closing pass on "Checklist audit 11/03 (BG + status split + count)"

Range: ffdb3018..HEAD on fix/night-1103-checklist. HEAD includes a merge of origin/main (schema-B sound_attempts, 3028e9c0) — main's own changes are out of scope; review this branch's commits (first parent). Your previous closing pass (cycle on ffdb3018..9f0c5ac2) returned 4 findings — paused MFO job lit Analyzing, pausing waiter filled the lens, viewer line lost to a leftover era job, a second Database cause unlogged — fixed in 8734f8ae; your second pass (ffdb3018..8734f8ae) found 2 more — a paused dossier batch still lit Analyzing, and a sidecar failure arriving together with a failed check was not logged — fixed in d5f466ba. Verify all six. Your cycle #220 found 7 findings; this branch claims to fix them plus a fresh-eyes reviewer's adds. Verify each invariant holds in the code at HEAD; report a finding only where one still fails (file:line, scenario, severity, checklist item).

The 7 invariants:
1. TRUE (data): the database a count or Catalog Database Info reads is the one the ROLE displays — master: cutover-opened else catalog.sqlite beside catalog.json; viewer: viewer-catalog/catalog.sqlite. ONE function (CatalogAuthority.databaseURL(role:opened:catalogFile:)) used by both callers. A viewer attempts no local era count; its job line says the master analyzes. "Viewer" is the sync role (catalogSync.mode / CatalogSync.launchMode), never catalogModel.isReadOnly.
2. TRUE: no surface shows progress the running work cannot move. Content "Analyzing N of M" only when a counted analyzer runs or the helper RUNS (not queued/paused/waiting) a job of a kind in BackgroundServiceActivity.feedsCountedAnalyzers (empty today). The era job is its own detail line ("Machine era: N of M files (VideoScan Background — <state>)").
3. TRUE: a job whose units defer is shown "waiting — <why>" with the waiting glyph (not the filled lens) in the menu bar and Settings; a queued job does not fill the lens. JobProgressSnapshot.waiting is additive (older payload decodes; schema stays 1).
4. WORKFLOW: the checkbox is disabled only when OFF and turning ON is refused; ON in Debug or on a viewer can be unchecked (unregister called). The "not registered" Fix names a verb this build can do.
5. PERFORMANCE: JobSupervisor.status() does not count as activity (menu bar's 5 s read); XPC status from the app does (noteClientActivity) — idle exit works with VideoScan closed.
6. LOGGING: every Settings ▸ Background problem (launchd states, not answering, gate refusal, count failure/recovery with path) and every Catalog Status line colour/cause change and every Catalog Database Info "unknown —" fact is logged once on appear/change/clear, never per poll/recompute. BackgroundCatalogAccess open refusal names the path.
7. TESTED: the count test uses a real schema-current catalog.sqlite with a known eligible count and requires .success through productionCountWork (master fallback, master opened-elsewhere, viewer no-count, DB Info viewer vs master).

Also: P0TruthRegressionTests now expects "Video+Audio · silent (measured)" (GH #417, Rick's 11/02 ruling).

Evidence: sensor lane GREEN (649 tests) at HEAD; touched app suites 106/106; Core background suites 75/75; gauntlet inventory --validate 0 errors.
Output contract: one finding per still-failing invariant with file:line, scenario, P0–P3, item. End with `Credits spent: … | Finding count: N` and `Verdict: merge|fix|block`. Stay within the changed files plus direct call sites.

---

# Codex review — Checklist audit 11/03 — closing

- Range: `ffdb3018..bdb227b5`
- Credits spent: unavailable
- Tokens: 105197
- Finding count: 1
- Verdict: fix — invariant 6 still suppresses changes between numbered drive names.
- Run: 2026-11-04T03:01:17Z (cycle #226, tools/codex_review.py)

## Codex answer

1. **P2 · LOGGING · invariant 6 — Numbered drive names still collapse into the same cause.**  
   [CatalogStatusLines.swift:516](/Users/rickb/dev/VideoScan-wt/night-1103/VideoScan/VideoScan/Analyze/CatalogStatusLines.swift:516) masks space-separated numbers inside paths. With Files remaining grey, change the offline drive from `/Volumes/Backup 1` to `/Volumes/Backup 2`, keeping counts unchanged. Both normalize to `/Volumes/Backup #`, so the displayed cause changes without a transition log.

   Replaying HEAD’s three regexes confirmed the collision. Regression: require these two causes to differ and the Files transition to emit one log entry. Preserve complete drive names when masking counts.

The seven previous closing-pass examples are fixed. Invariants 1–5 and 7, GH #417’s wording, and remaining scoped files: **read, no findings**. Main’s merged changes were excluded.

Swift tests could not run: the read-only sandbox returned `permissionDenied` before test execution. Supplied green counts were not independently reproduced.

Credits spent: unavailable | Finding count: 1  
Verdict: fix — invariant 6 still suppresses changes between numbered drive names.

## Brief

# Codex brief — closing pass on "Checklist audit 11/03 (BG + status split + count)"

Range: ffdb3018..HEAD on fix/night-1103-checklist. HEAD includes a merge of origin/main (schema-B sound_attempts, 3028e9c0) — main's own changes are out of scope; review this branch's commits (first parent). Your previous closing pass (cycle on ffdb3018..9f0c5ac2) returned 4 findings — paused MFO job lit Analyzing, pausing waiter filled the lens, viewer line lost to a leftover era job, a second Database cause unlogged — fixed in 8734f8ae; your second pass (ffdb3018..8734f8ae) found 2 more — a paused dossier batch still lit Analyzing, and a sidecar failure arriving together with a failed check was not logged — fixed in d5f466ba; your third pass found the cause normalizer stripped every digit (drive X8→X9 hidden, '2,000' comma) — fixed in bdb227b5 (masks ages, times and free-standing numbers only). Verify all seven. Your cycle #220 found 7 findings; this branch claims to fix them plus a fresh-eyes reviewer's adds. Verify each invariant holds in the code at HEAD; report a finding only where one still fails (file:line, scenario, severity, checklist item).

The 7 invariants:
1. TRUE (data): the database a count or Catalog Database Info reads is the one the ROLE displays — master: cutover-opened else catalog.sqlite beside catalog.json; viewer: viewer-catalog/catalog.sqlite. ONE function (CatalogAuthority.databaseURL(role:opened:catalogFile:)) used by both callers. A viewer attempts no local era count; its job line says the master analyzes. "Viewer" is the sync role (catalogSync.mode / CatalogSync.launchMode), never catalogModel.isReadOnly.
2. TRUE: no surface shows progress the running work cannot move. Content "Analyzing N of M" only when a counted analyzer runs or the helper RUNS (not queued/paused/waiting) a job of a kind in BackgroundServiceActivity.feedsCountedAnalyzers (empty today). The era job is its own detail line ("Machine era: N of M files (VideoScan Background — <state>)").
3. TRUE: a job whose units defer is shown "waiting — <why>" with the waiting glyph (not the filled lens) in the menu bar and Settings; a queued job does not fill the lens. JobProgressSnapshot.waiting is additive (older payload decodes; schema stays 1).
4. WORKFLOW: the checkbox is disabled only when OFF and turning ON is refused; ON in Debug or on a viewer can be unchecked (unregister called). The "not registered" Fix names a verb this build can do.
5. PERFORMANCE: JobSupervisor.status() does not count as activity (menu bar's 5 s read); XPC status from the app does (noteClientActivity) — idle exit works with VideoScan closed.
6. LOGGING: every Settings ▸ Background problem (launchd states, not answering, gate refusal, count failure/recovery with path) and every Catalog Status line colour/cause change and every Catalog Database Info "unknown —" fact is logged once on appear/change/clear, never per poll/recompute. BackgroundCatalogAccess open refusal names the path.
7. TESTED: the count test uses a real schema-current catalog.sqlite with a known eligible count and requires .success through productionCountWork (master fallback, master opened-elsewhere, viewer no-count, DB Info viewer vs master).

Also: P0TruthRegressionTests now expects "Video+Audio · silent (measured)" (GH #417, Rick's 11/02 ruling).

Evidence: sensor lane GREEN (649 tests) at HEAD; touched app suites 106/106; Core background suites 75/75; gauntlet inventory --validate 0 errors.
Output contract: one finding per still-failing invariant with file:line, scenario, P0–P3, item. End with `Credits spent: … | Finding count: N` and `Verdict: merge|fix|block`. Stay within the changed files plus direct call sites.

---

# Codex review — Checklist audit 11/03 — closing

- Range: `ffdb3018..29fe2dc8`
- Credits spent: unavailable
- Tokens: 113804
- Finding count: 1
- Verdict: fix — invariant 6 still suppresses genuine drive-name changes.
- Run: 2026-11-04T03:10:03Z (cycle #227, tools/codex_review.py)

## Codex answer

1. **P2 · LOGGING · invariant 6 — Parenthesized drive numbers still collapse.**  
   [CatalogStatusLines.swift:526](/Users/rickb/dev/VideoScan-wt/night-1103/VideoScan/VideoScan/Analyze/CatalogStatusLines.swift:526) stops protecting a path at ` (`. With Files remaining grey, replace offline `/Volumes/Backup (1)` with `/Volumes/Backup (2)`, keeping counts unchanged. Both causes normalize to `/Volumes/Backup (#)`, so the changed drive produces no log entry.

   Confirmed by replaying HEAD’s regexes through Foundation `NSRegularExpression`. Regression: require different normalized causes and exactly one Files transition. Compare structured causes while excluding count/age fields rather than inferring path boundaries from prose.

All eight previous examples are fixed in code and have regression coverage. Invariants 1–5 and 7, GH #417’s wording, and remaining scoped changes: **read, no findings**. Reviewed through `29fe2dc88`; main’s merged changes were excluded.

The targeted Core test attempt failed before execution with sandbox `permissionDenied`. Supplied green counts were not independently reproduced. No files changed.

Credits spent: unavailable | Finding count: 1  
Verdict: fix — invariant 6 still suppresses genuine drive-name changes.

## Brief

# Codex brief — closing pass on "Checklist audit 11/03 (BG + status split + count)"

Range: ffdb3018..HEAD on fix/night-1103-checklist. HEAD includes a merge of origin/main (schema-B sound_attempts, 3028e9c0) — main's own changes are out of scope; review this branch's commits (first parent). Your previous closing pass (cycle on ffdb3018..9f0c5ac2) returned 4 findings — paused MFO job lit Analyzing, pausing waiter filled the lens, viewer line lost to a leftover era job, a second Database cause unlogged — fixed in 8734f8ae; your second pass (ffdb3018..8734f8ae) found 2 more — a paused dossier batch still lit Analyzing, and a sidecar failure arriving together with a failed check was not logged — fixed in d5f466ba; your third pass found the cause normalizer stripped every digit (drive X8→X9 hidden, '2,000' comma) — fixed in bdb227b5 (masks ages, times and free-standing numbers only). Your fourth pass found numbered drive names with spaces ('Backup 1'→'Backup 2') still collapsed — fixed in the head commit (path spans kept verbatim). Verify all eight. Your cycle #220 found 7 findings; this branch claims to fix them plus a fresh-eyes reviewer's adds. Verify each invariant holds in the code at HEAD; report a finding only where one still fails (file:line, scenario, severity, checklist item).

The 7 invariants:
1. TRUE (data): the database a count or Catalog Database Info reads is the one the ROLE displays — master: cutover-opened else catalog.sqlite beside catalog.json; viewer: viewer-catalog/catalog.sqlite. ONE function (CatalogAuthority.databaseURL(role:opened:catalogFile:)) used by both callers. A viewer attempts no local era count; its job line says the master analyzes. "Viewer" is the sync role (catalogSync.mode / CatalogSync.launchMode), never catalogModel.isReadOnly.
2. TRUE: no surface shows progress the running work cannot move. Content "Analyzing N of M" only when a counted analyzer runs or the helper RUNS (not queued/paused/waiting) a job of a kind in BackgroundServiceActivity.feedsCountedAnalyzers (empty today). The era job is its own detail line ("Machine era: N of M files (VideoScan Background — <state>)").
3. TRUE: a job whose units defer is shown "waiting — <why>" with the waiting glyph (not the filled lens) in the menu bar and Settings; a queued job does not fill the lens. JobProgressSnapshot.waiting is additive (older payload decodes; schema stays 1).
4. WORKFLOW: the checkbox is disabled only when OFF and turning ON is refused; ON in Debug or on a viewer can be unchecked (unregister called). The "not registered" Fix names a verb this build can do.
5. PERFORMANCE: JobSupervisor.status() does not count as activity (menu bar's 5 s read); XPC status from the app does (noteClientActivity) — idle exit works with VideoScan closed.
6. LOGGING: every Settings ▸ Background problem (launchd states, not answering, gate refusal, count failure/recovery with path) and every Catalog Status line colour/cause change and every Catalog Database Info "unknown —" fact is logged once on appear/change/clear, never per poll/recompute. BackgroundCatalogAccess open refusal names the path.
7. TESTED: the count test uses a real schema-current catalog.sqlite with a known eligible count and requires .success through productionCountWork (master fallback, master opened-elsewhere, viewer no-count, DB Info viewer vs master).

Also: P0TruthRegressionTests now expects "Video+Audio · silent (measured)" (GH #417, Rick's 11/02 ruling).

Evidence: sensor lane GREEN (649 tests) at HEAD; touched app suites 106/106; Core background suites 75/75; gauntlet inventory --validate 0 errors.
Output contract: one finding per still-failing invariant with file:line, scenario, P0–P3, item. End with `Credits spent: … | Finding count: N` and `Verdict: merge|fix|block`. Stay within the changed files plus direct call sites.
