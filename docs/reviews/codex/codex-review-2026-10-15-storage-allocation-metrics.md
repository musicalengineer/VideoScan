# Codex review — Storage allocation + metrics classification + Trash wording

- Range: `12a9f5ee0..c6625b218`
- Credits spent: unavailable (no billing telemetry)
- Tokens: 100146
- Finding count: 4
- Verdict: fix — physical-unit attribution violates invariant 1.
- Run: 2026-10-16T01:11:58Z (cycle #76, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (no billing telemetry) | Finding count: 4
Verdict: fix — physical-unit attribution violates invariant 1.

1. **P1 — Fusion containers are attributed to only their first physical disk.** [DriveAllocationProbe.swift:122](/Users/rickb/dev/VideoScan/VideoScan/Volumes/DriveAllocationProbe.swift:122) selects `stores.first`, ignoring additional stores.

   Failure scenario: an APFS container spanning `disk4` and `disk5` displays only disk4’s name and potentially its SSD/HDD classification. Return unknown unless the representation supports multiple physical units.

   RED case for `DriveAllocationProbeTests`, extending its existing APFS and plain-volume identifiers; currently returns `"disk4"`:

   ```swift
   @Test func multiStoreIsNotOnePhysicalUnit() {
       let plist: [String: Any] = [
           "DeviceIdentifier": "disk7s1",
           "APFSPhysicalStores": [
               ["APFSPhysicalStore": "disk4s2"],
               ["APFSPhysicalStore": "disk5s2"]
           ]
       ]
       #expect(DriveAllocationProbe.wholeDisk(fromVolumeInfo: plist) == nil)
   }
   ```

2. **P1 — Missing or malformed APFS stores fall back to the virtual disk.** [DriveAllocationProbe.swift:126](/Users/rickb/dev/VideoScan/VideoScan/Volumes/DriveAllocationProbe.swift:126) unconditionally accepts `DeviceIdentifier` after physical-store parsing fails.

   Failure scenario: the existing APFS fixture loses its physical-store entry; the parser returns `"disk7"` and subsequently probes that virtual device as physical hardware. APFS resolution must fail closed.

   RED case for `DriveAllocationProbeTests`, combining its existing APFS identifier and empty-store fixture; currently returns `"disk7"`:

   ```swift
   @Test func emptyAPFSStoresNeverUseVirtualDisk() {
       let plist: [String: Any] = [
           "DeviceIdentifier": "disk7s1",
           "APFSPhysicalStores": [[String: Any]]()
       ]
       #expect(DriveAllocationProbe.wholeDisk(fromVolumeInfo: plist) == nil)
   }
   ```

3. **P2 — “First reachable” actually means “first with free bytes.”** [DriveAllocationProbe.swift:68](/Users/rickb/dev/VideoScan/VideoScan/Volumes/DriveAllocationProbe.swift:68): an offline entry followed by a reachable entry whose filesystem query fails retains the offline entry’s capacity/type; selection needs explicit reachability provenance.

   RED case in `DriveAllocationProbeTests`, using its `FamilyArchive` label and HDD/SSD facts; the absent path simulates a failed probe after reachability was captured. Currently retains 1 TB:

   ```swift
   @Test func reachableFallbackReplacesOfflineFallback() async {
       let path = "/Volumes/test_missing_\(UUID().uuidString)"
       let requests: [DriveAllocationProbe.Request] = [
           .init(label: "FamilyArchive", path: path, mediaTech: .hdd,
                 isReachable: false, capacityTB: 1),
           .init(label: "FamilyArchive", path: path, mediaTech: .ssd,
                 isReachable: true, capacityTB: 8)
       ]
       let facts = await DriveAllocationProbe.facts(for: requests)
       #expect(facts["FamilyArchive"]?.capacityBytes == 8_000_000_000_000)
       #expect(facts["FamilyArchive"]?.typeLabel == VolumeMediaTech.ssd.rawValue)
   }
   ```

4. **P3 — Unknown physical units disappear instead of showing “—”.** [CatalogDistributionPane.swift:452](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogDistributionPane.swift:452): a failed unit lookup renders just `FamilyArchive`; RED replacement assertion in the existing `rowName()` test, reusing `fa`: `#expect(CatalogDistributionPane.rowName(fa, facts: nil, host: "RicksM4") == "FamilyArchive (—)")`.

The remaining checks hold within the scoped source: invariant 2’s unreachable-capacity fallback, optional free percentage, and home naming; invariant 3’s protection against a later offline answer blanking successful space data; invariant 4’s detached probing and cached view rendering with O(targets) getter access; and invariant 6’s permission codes, folder-derived wording, and system-description fallback. Swift tests above are proposed RED cases, not executed; no app build or launch occurred.

`tools/publish_metrics.py`, `docs/index.html`, the sidebar wording in `VolumesWindow.swift`, and the scoped Trash wording: **read, no findings**. Invariant 5 passed 14 existing classification cases and the 90-night test executed in memory, plus the existing dashboard harness checking 270 cells, worst-Mac failure count, red-only totals, watch-last-night wording, and “?” styling. No files written.

## Brief

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

## Closure

Branch `feature/compare-media` (worktree), closed the same night; DriveAllocationProbeTests 8 — green (Debug). The metrics classification, the page and the Trash wording: read, no findings.

| Finding | Closure | Pinning test |
|---|---|---|
| F1 P1 a Fusion container is attributed to its first store | fixed: `wholeDisk(fromVolumeInfo:)` — an APFS volume resolves only through EXACTLY one physical store; two stores → nil (unknown), shown as "(—)" | `DriveAllocationProbeTests.multiStoreIsNotOnePhysicalUnit` (codex's case) |
| F2 P1 an empty/malformed store list falls back to the virtual disk | fixed: when the `APFSPhysicalStores` key is present the virtual `DeviceIdentifier` is never used — fails closed | `DriveAllocationProbeTests.emptyAPFSStoresNeverUseVirtualDisk` (codex's case + malformed entries + wrong type) |
| F3 P2 "first reachable" meant "first with free bytes" | fixed: `facts(for:)` keeps reachability provenance per label — a reachable answer always replaces an unreachable one; between equals the one with free bytes wins; a later unreachable answer never replaces | `DriveAllocationProbeTests.reachableFallbackReplacesOfflineFallback` (codex's case, both orders) |
| F4 P3 an unknown unit disappears | fixed: `rowName` shows "(—)" when the disk could not say; the folded "Other" row has no unit | `DriveAllocationProbeTests.rowName` (codex's replacement assertions) |

## Closed

Closed by `5d827f744` at 2026-10-16T01:20:10Z. 4 findings closed (Fusion unknown, APFS fails closed, reachable wins, unknown unit shown); metrics + wording no findings
