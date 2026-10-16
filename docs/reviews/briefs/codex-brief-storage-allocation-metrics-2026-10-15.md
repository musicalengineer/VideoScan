# Codex brief: Storage ▸ Media Allocation by Drive, the metrics page's night classification, and the read-only-folder Trash wording

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~1,000 words. For each finding include a RED test case (Swift Testing for the app, pytest for the publisher) using the fixtures already in the named test files.

**One sentence (Rick, 2026-10-15):** one Storage view that shows where the media lives — volume and its physical unit, type, reliability, media bytes, % of catalog, capacity, % free, files — and a metrics page whose colours say what happened: green all passed, yellow a few failed, red broken, a "?" when nothing ran.

**Why it matters:** these are read-only views, but Rick decides from them where to put and remove media; a wrong capacity, a volume attributed to the wrong physical unit, or a night coloured green that was red misleads the person who holds the delete button. The Trash wording is what he reads when a removal fails.

**Range:** main `12a9f5ee0..c6625b218`. Read files with `git show c6625b218:<path>`.
- `VideoScan/VideoScan/Volumes/DriveAllocationProbe.swift` — `DriveAllocationFacts` (+ `freePercent`), `DriveAllocationProbe.facts(for:)` → `facts(for:units:)`, `filesystemSpace(atPath:)`, `unit(forMount:cache:)`, the pure `wholeDisk(fromVolumeInfo:)` and `unitName(fromMediaName:)`, `diskutilInfo` (ProcessRunner, 10 s deadline).
- `VideoScan/VideoScan/Catalog/CatalogDistributionPane.swift` — `CatalogDistributionStats.factsByDrive`, `Inputs.factsByDrive`, `compute`, `header`, `Col`, `rowName`, `hostDisplayName`, `driveLegend`, `freeColor`, `recompute` (the requests built on the main actor; the probe in the detached task before `compute`).
- `VideoScan/VideoScan/Volumes/VolumesWindow.swift` — the sidebar row's words only.
- `tools/publish_metrics.py` — `NIGHT_STATES`, `WATCH_MAX_FAILED`, `classify_nightly_row`, `nightly_summary` (unchanged, reads the result), the `_NIGHT` schema.
- `docs/index.html` — the night states on the page: `cellWords`, `anyWatch`/`anyFailing`, `stability`, the Last-night tile (`failing` = the worst Mac, `lastWatch`), the timeline cells (`.cell.watch`, `.cell.did_not_run` with the "?"), the not-green table, the Tests & nightly area line (`watches`).
- `VideoScan/VideoScan/MediaOps/VideoScanModel+JunkTrashSnapshot.swift` — `trashFailureNote` → pure `trashFailureWords(volume:path:error:parentWritable:)`.
- Tests: `VideoScan/VideoScanTests/DriveAllocationProbeTests.swift` (5), `tests/test_publish_summary.py` (`test_did_not_run_rule` cases, the 90-night table), `tests/test_metrics_dashboard.py` (the timeline counts, the Last-night tile), `VideoScan/VideoScanTests/CleanupTrashHardeningTests.swift::readOnlyFolderWording`.

**Invariants to attack (prove with file:line or say it holds):**
1. The physical unit: two volumes on one box get the same `wholeDisk` and name; an APFS volume resolves through its physical store, never its virtual disk; a non-APFS volume through its device identifier; a volume whose `diskutil` answer is missing, malformed, or slow leaves `unitName`/`wholeDisk` nil and the row shows "—", never a crash or a wrong unit; a Fusion / multi-store APFS container (two `APFSPhysicalStores`) does not misattribute.
2. Capacity and free: statfs only when the target is reachable; an unreachable target keeps the editor's TB figure and shows "—" for free; `freePercent` is nil without both numbers or with capacity 0; the home-folder targets probe the boot volume and are labelled "<host> (system)" (no ".local").
3. Several targets sharing one label ("Mac (home)", two folders on one volume): the first REACHABLE answer wins and a later unreachable one never blanks capacity/free.
4. Main-actor hygiene: `recompute` builds requests on the main actor from the targets' published getters once (O(targets)); every stat and `diskutil` call runs in the detached task; nothing in `driveLegend` or any body walks records or calls the probe; `hostDisplayName` is cheap.
5. Night classification: `watch` iff 0 < failed < 10 AND (status ok OR reason starts with "failed-tests:"); `red` for failed ≥ 10, a non-failed-tests reason with status failed, or failed > 0 with status failed and another reason; `did_not_run` iff total == 0; `crashed_names` never decides; the page never classifies on its own (it reads `state`), the Last-night tile's failing count is the worst Mac's, never a sum; `stability.redNights` counts red only; a watch night with no red/green streak reads "a few tests failed last night".
6. The Trash wording: a permission error (Cocoa 513/257 or POSIX EACCES/EPERM) in a non-writable parent folder names the folder and the fix; a permission error in a writable folder, or any other error, keeps the system's words; the path/volume words never leak a different file's name.

**Do only this:** findings against 1–6 (P1 first), each with file:line, a one-line failure scenario and the red test; then at most three P2/P3 one-liners. Out of scope: the Media Size column / storage totals (reviewed earlier), the timeline's demo tags, the gauntlet, the coverage job.

**Do not explore outside the files listed above and their tests.**
