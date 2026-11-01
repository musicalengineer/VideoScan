# Codex review — #383 editor caches + Tidy set-aside

- Range: `17485b1fe..42bcb9b91`
- Credits spent: unavailable
- Tokens: 146671
- Finding count: 3
- Verdict: fix — symlinked roots bypass exclusion, filename/size collisions can hide unrelated family footage, and resume omits cache skips from its audit.
- Run: 2026-10-26T01:08:10Z (cycle #140, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 3
Verdict: fix — symlinked roots bypass exclusion, filename/size collisions can hide unrelated family footage, and resume omits cache skips from its audit.

1. **P1 — Different family footage can inherit the cache label without matching content.** [VideoScanModel+TidyCatalog.swift:303](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/VideoScanModel+TidyCatalog.swift:303)

   The new cache category feeds the existing ignore-list fallback in [IgnoredContentStore.swift:62](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/IgnoredContentStore.swift:62): an unhashed record matches by filename and size alone.

   **Reproduction:** Tidy `Project/iMovie Cache/Cache.mov`; then introduce a different, unhashed `Family/Christmas1990/Cache.mov` of equal size. The second Tidy plan labels it “Junk that came back — editor-cache”; a scan at a new path excludes it. This exceeds the accepted **byte-identical** exception.

   **Regression to add:** use different bytes with equal filename/size; after tidying the cache, assert the family record remains admitted and absent from the next Tidy plan. Require content evidence before propagating the cache reason outside cache directories.

2. **P1 — A symlinked root still admits cache files.** [FilesystemWalker.swift:137](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Volumes/FilesystemWalker.swift:137)

   The root precondition checks its literal spelling. Directory enumeration follows a root symlink, while the subsequent file branch never checks its enclosing cache path.

   **Reproduction:** retain a scan target `Preview`, make it a symlink to `Project/Render Files`, and place `clip.mov` there. Scanning `Preview` passes the root check and emits the movie. The downstream catalog-scope gate admits video.

   **Regression to add:** extend the root-review fixture with that symlink; assert `found.isEmpty` and one audited cache rejection. Check the resolved root before enumeration.

3. **P2 — Resume reports zero cache-directory skips after dropping cache files.** [VideoScanModel+ScanExecution.swift:672](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Volumes/VideoScanModel+ScanExecution.swift:672)

   Filtering writes only a console message. The collector created at line 699 never receives those exclusions.

   **Reproduction:** resume a checkpoint containing two files under one `Render Files` directory. Both disappear from the probe list, but the final audit and sidecar report `skippedEditorCacheDirs == 0`, with no sampled paths. A fresh walk reports one.

   **Regression to add:** assert one directory and its sampled path after resume; deduplicate files and nested cache paths consistently with the walk.

The regression recipes above are **not executed RED tests**. Existing selected tests passed: **15 tests / 7 suites / 0 failures**, Debug, isolated DerivedData.

Lizard confirms `walkTree` **CCN 15**; no new function exceeds 15. `finalizeSingleTargetScan` remains **17**, unchanged from the base.

Other scoped files:

- `ScanOptions.swift` — read, no findings.
- `CatalogScopePolicy.swift` — read, no findings.
- `DiscoveryAudit.swift` — read, no findings.
- `TidyCatalogSheet.swift` — read, no findings.
- `EditorCacheSkipTests.swift` — read, no findings.
- `EditorCacheSkipReviewTests.swift` — read, no findings.
- `TidyCatalogSheetLayoutTests.swift` — read, no findings.

I followed scan admission/merge/preservation and ignore-list helpers beyond the named files to verify these interactions. No deletion, byte modification, or user-field loss found in Tidy apply/undo. Checkout unchanged; the pre-existing Charter edit remains.

## Brief

# Codex review brief — #383 editor caches: three scan doors + Tidy Catalog set-aside

**Workflow in one sentence (Rick's words):** "our provenance gate lets these in" — iMovie / Final Cut render caches (`iMovie Movie Cache/Cache-30.mov`, `iMovie Cache/Cache.mov`, `Render Files`, `iMovie Thumbnails`…) must never be admitted by a scan, whatever the scan options, and Tidy Catalog must set the ~619 existing rows aside (hidden, remembered, never deleted).

**Range:** `17485b1fe..42bcb9b91` on branch `overnight/2026-10-25` · **Checkout:** `/Users/rickb/dev/VideoScan` (read-only for you)

**In scope (read these and their direct callers; nothing else):**
- `VideoScan/VideoScan/Volumes/ScanOptions.swift` — `SkipCategories.editorCacheDirs`
- `VideoScan/VideoScan/Volumes/FilesystemWalker.swift` — the walk: directory names checked unconditionally before `policy.skipDirs`; `walkTree` root precondition
- `VideoScan/VideoScan/Catalog/CatalogScopePolicy.swift` — `isEditorCachePath(_:)`, `isEditorCacheDirectory(_:)`
- `VideoScan/VideoScan/Volumes/VideoScanModel+ScanExecution.swift` — the resume door: `checkpoint.discoveredPaths` filtered with `isEditorCachePath`
- `VideoScan/VideoScan/Volumes/DiscoveryAudit.swift` — `skippedEditorCacheDirs`, capped `skippedEditorCacheDirPaths`, the sidecar
- `VideoScan/VideoScan/Catalog/VideoScanModel+TidyCatalog.swift` — the tally (`editorCacheCount`), the rows, `applyTidyCatalog` writing `setAsideReason = .editorCache` (a CATALOG WRITER: rule 10 shape — rows are never deleted, only marked)
- `VideoScan/VideoScan/Catalog/TidyCatalogSheet.swift` — `TidyCatalogCountsGrid`
- Tests: `VideoScan/VideoScanTests/EditorCacheSkipTests.swift`, `EditorCacheSkipReviewTests.swift`, `TidyCatalogSheetLayoutTests.swift`

**Invariants to attack** (one line each):
1. **No door admits a cache file.** Three doors exist: a scan root chosen by Rick, the recursive walk, and checkpoint resume. Show a path (spelling, case, symlink, a cache folder nested in a cache folder, a `.localized` suffix, a package bundle such as `*.imovielibrary` / `*.fcpbundle`, a trailing slash, a Unicode-normalised name) where a file under an editor cache directory still reaches the catalog. The set is name-based by design; `Thumbnails` alone is deliberately NOT skipped (31 generic folders on Rick's drives). `docs/DECISIONS.md` 2026-10-25 line.
2. **Tidy never deletes and never touches bytes.** `applyTidyCatalog` for `.editorCache` rows must only set `setAsideReason`; the files and the rows stay; Undo restores the batch; a rescan does not bring the rows back (content-keyed ignore list). Show a row that is purged, tombstoned, or loses a user field (user date, note, tag, people) on set-aside or on put-back.
3. **A real family video is never set aside as a cache.** Rick's own `Christmas1990` tape transfers live NEXT TO the `iMovie Movie Cache` folder (`…/iMovie Events.localized/Christmas1990/…`). Show an ordinary path that `isEditorCachePath` matches (false positive), e.g. a family folder literally named "Render Files" or a file named `Cache.mov` outside a cache dir (content-keyed ignore list: a byte-identical cache file at a non-cache path hides under the cache label — accepted per the 2026-09-11 ruling; do not report that one).
4. **Resume agrees with the walk.** A scan interrupted before #383 and resumed after it must drop the cache paths from `discoveredPaths` AND count them in the audit; show a resume that double-counts, drops a non-cache path, or logs a count that disagrees with the walk's.
5. **Complexity gate.** `walkTree` was kept at CCN ≤ 15 by extracting the root check; confirm no new function in scope exceeds 15 (lizard CCN).

**Evidence already run:** EditorCacheSkipTests 5 suites / 12 tests; EditorCacheSkipReviewTests 1 (the reviewer's RED test: a scan rooted inside a cache dir admitted everything before `db2f3fec9`); worker's related run 139 tests / 32 suites green; sensor lane GREEN 570 on the pre-merge tree; manifest floor 2979 validated (three pre-existing validator errors are #377, not this change). Fresh-eyes reviewer verdict: Good.

**Known and accepted (do not report):** name-based matching (no content sniffing) — Rick's ruling; `Thumbnails` generic folders not skipped; content-keyed ignore list hiding a byte-identical cache file at a non-cache path; `ExternalPlayerAudioRouteTests` manifest drift (#377).

**Output contract:**
```
Credits spent: <amount> | Finding count: <N>
Verdict: merge | fix | block — <one sentence>
```
Then findings ranked by data-loss risk, each with `file:line`, a reproduction, and a RED test where possible. For every in-scope file with nothing to report write "read, no findings." Do not explore outside the files above unless a finding requires it, and say so.
