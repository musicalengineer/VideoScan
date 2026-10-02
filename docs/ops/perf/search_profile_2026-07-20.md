# Catalog Search Profile — GH #123 (2026-07-20)

Performance-agent diagnosis of "search over ~103k records is way too slow
and beachballs." **Diagnosis + fix plan only — no production code changed.**

- Machine: M4 Max Mac Studio · macOS 26 · Xcode 26.3
- Config: **Release** (`-configuration Release`, whole-module `-O`) — per
  build-mode policy; all numbers below are Release wall-clock.
- Harness: `VideoScanTests/CatalogSearchProfileBench.swift` (committed on
  this branch) — 100k synthetic records matched to the real catalog's
  measured shape (see "Corpus" below). Deterministic, seeded.
- Real-catalog shape read (read-only) from
  `~/Library/Application Support/VideoScan/catalog.json` on 2026-07-19.

## TL;DR — ranked dominant costs

| # | Cost | Measured (per settled keystroke, main thread) | Class |
|---|------|-----------------------------------------------|-------|
| 1 | **Poisoned (empty) persisted search index** — Rick's machine was in this state during the spot test | **5.4–5.5 s** | bug (state poisoning) |
| 2 | **yearRange tokens** ("1990s", "199x", "year:", "decade:") — always linear, `pfYearsFromRecord` per record | **1.9 s** | algorithmic gap |
| 3 | **Everything runs twice** — table filter + toolbar badge are two independent full scans on the same debounce edge | 2× multiplier on every row above | duplicated work |
| 4 | Healthy-index substring queries (linear fallback regime) | 117–144 ms | O(n) on main |
| 5 | Healthy-index substring queries (word fast-path regime) | ~61 ms | O(n) floor (per-record Set/hash pass) |
| 6 | Launch-time index rebuild on the main actor | 5.97 s bench / **7.13 s real** (catalog.log 19:10:09) | launch beachball |
| 7 | Column-header sort (`model.records.sort(using:)` + `tableData.sort`) on main | 2.5 s (filename) / 0.56 s (resolvedDate) | adjacent, same class |

The #124 A/V-only default shrinks the working set 100k → 17.8k and buys
**~6–7×** on its own (measured below).

## The smoking gun (finding 1)

Rick's search wasn't slow because the index is slow — it was slow because
**the index was empty**.

Evidence chain (all verified 2026-07-19):

1. `~/Library/Application Support/VideoScan/catalog.search-index.v1.plist`
   is **110 bytes**: `version: 1, recordCount: 0, savedAt: 17:27 (2026-07-19),
   haystacks: {}` — zero haystacks for a 103,835-record catalog.
2. `catalog.log`: `Search index loaded from disk in 0 ms (103832 records)`
   at 14:07, 14:38, and 18:06 that day — the app **accepted** the empty
   index. (`loadFromDisk` checks version + mtime-staleness only; there is
   **no recordCount-vs-catalog sanity check** —
   `CatalogSearchIndex.swift` `loadFromDisk`.)
3. Who wrote it: `VideoScanModel.init` → index load/rebuild/save block
   (`VideoScanModel.swift:770–785`) has **no `TestEnvironment.isTestHost`
   guard and no path redirect**. Under any test host, `CatalogStore.load()`
   correctly short-circuits to `[]` (settings-pollution guard), so the
   model then runs `searchIndex.rebuild(records: [])` **and
   `saveToDisk()` to the real App Support path** — overwriting Rick's
   index with the 110-byte empty file. Every unit-test run on this
   machine re-poisons it. This is the settings-pollution class
   (checklist dimension 4) hitting a file the guards missed.
4. Consequence: with 0 haystacks and 0 indexed words, every query takes
   `matches()`'s "defensive fallback" — `buildHaystack()` runs **inline
   per record per query** (multi-field concat + `pathTokenize` ×3 +
   lowercase + NFC). Measured: **2.7 s per pass, ×2 passes = 5.4–5.5 s
   of main-thread work per settled keystroke**. That is the reported
   beachball, reproduced quantitatively.

Why it comes and goes: the poison file is only accepted while its
`savedAt` ≥ catalog.json's mtime. Any catalog save invalidates it → next
launch pays the 6–7 s **main-thread rebuild** (finding 6) and search is
healthy again — until the next test run re-poisons. Intermittent by
construction.

## Measured numbers (Release, M4 Max, 100k Rick-shaped records)

`settled_keystroke_ms` = table filter + badge count, i.e. total main-thread
predicate work on the trailing edge of the 250 ms debounce (both real
debouncers fire together). SwiftUI Table diffing is NOT included (see
"Residual unknown").

### Healthy index, full 100k working set

| query | table ms | badge ms | settled ms | hits | regime |
|---|---|---|---|---|---|
| `donna` | 30.7 | 30.6 | **61.3** | 4,876 | word fast-path |
| `mark dan grampa` | 31.0 | 30.7 | **61.7** | 3,993 | word fast-path |
| `1993` | 58.2 | 58.9 | **117.1** | 11,297 | linear (infix gate bails: "v1993…", "capecod1993" words exist) |
| `christmas` | 66.1 | 65.4 | **131.5** | 2,335 | linear (infix of "christmas1995"-style words) |
| `mov` | 66.5 | 67.2 | **133.7** | 12,256 | linear (infix of "imovie") |
| `"cape cod"` | 64.9 | 64.9 | **129.9** | 2,337 | linear (phrase always bails) |
| `elev` | 71.5 | 72.2 | **143.7** | 0 | linear (partial word) |
| `1990s` | 951.7 | 952.2 | **1,903.9** | 45,640 | yearRange — always linear + `pfYearsFromRecord`/record |
| `donna 1990s` | 107.0 | 108.0 | **214.9** | 3,560 | substring narrows, then yearRange on survivors |

Also: `prefilter_passes_ms=9.8` (purge+set-aside passes),
`index_rebuild_ms=5,966`, `indexed_words=100,307`,
`sort_by_filename_ms=2,511`, `sort_by_resolvedDate_ms=561`.

### Poisoned empty index (Rick's actual state during the spot test)

| query | settled ms | hits |
|---|---|---|
| `1993` | **5,480** | 11,297 |
| `donna` | **5,401** | 4,876 |
| `donna 1990s` | **5,528** | 3,560 |

Hit counts agree exactly with the healthy index (asserted in the bench —
doubles as an index/canonical agreement sensor at 100k).

### A/V-only working set (the #124 default) — 17,785 rows

| query | settled ms | vs full |
|---|---|---|
| `donna` | 6.0 | 10× |
| `1993` | 16.2 | 7.2× |
| `donna 1990s` | 32.7 | 6.6× |
| `1990s` | 306.8 | 6.2× |

## Hypothesis answers (task §3)

**(a) Is the predicate O(records × string ops) per keystroke on the main
actor?** Per *raw* keystroke: no — typing only resets two 250 ms debounce
tasks (ContentView + CatalogToolbar run independent, duplicate
debouncers); no O(n) work per character. Per *settled* keystroke (250 ms
after typing stops): yes — everything above runs on the main actor.
`CatalogContent.computeFiltered()` (via `.onChange(of: searchText)` in
`CatalogContent+Table.swift:826`) and
`CatalogToolbar.recomputeSearchHitCount()` each do a full O(records) pass.
Even the inverted-index "fast path" is O(n): it still runs
`records.filter { candidatePaths.contains($0.fullPath) }` — ~30 ms of
hashing 137-char path strings per pass. The word fast-path also almost
never fires for realistic needles: the infix-safety gate
(`isFastPathEligible`) bails whenever the needle appears inside ANY other
indexed word ("1993" in "v1993…", "mov" in "imovie", "christmas" in
"christmas1995"), sending the whole query to the linear memmem scan.

**(b) Are derived per-row values computed inside the filter?** Mostly no —
the haystack cache exists precisely to avoid that, and resolved dates
(#117) are NOT in the search path; `resolvedDateSortKey` is genuinely O(1)
integer math (verified `VideoRecordUserDate.swift`). Two real exceptions:
(1) the poisoned-index state makes `buildHaystack` run per record per
query — the actual reported bug; (2) yearRange tokens run
`pfYearsFromRecord` per record per query — a char-by-char scan of
path+filename plus **two `Calendar.component` calls and a
`Calendar(identifier:)` init per record** (`CatalogQueries.swift:219-251`)
≈ 9.5 µs/record → 952 ms/pass. Volume status is NOT consulted per row in
the filter (only by the `.onlineOnly` view chip, off by default).

**(c) Is there debounce?** Yes — two independent 250 ms trailing-edge
debouncers (ContentView:530-548 for the table, CatalogToolbar:381-399 for
the badge). Debounce is fine; the problem is what runs on the trailing
edge, and that it runs twice.

**(d) Does the results diff/table update dominate?** Not measurable at
unit level and NOT needed to explain the report: the measured predicate
work (5.4 s poisoned, 1.9 s yearRange) already accounts for the
beachballs. `tableData` replacement triggers an NSTableView-backed
rebuild that is O(rows) but constant-light; recommend one os_signpost /
Instruments confirmation during the fix's spot test. Residual, not
dominant.

**(e) What does #124's A/V default buy on its own?** 6–10× on every query
class (table above). Worth shipping regardless, but note it does NOT fix
finding 1 (poisoned index — still 950 ms/pass at 17.8k rows) or make
"1990s" comfortable (307 ms on main).

## Fix plan — small PRs, in order

**PR A (P0, tiny) — stop the index poisoning + refuse poisoned files.**
1. Gate the whole load/rebuild/save block in `VideoScanModel.init`
   (VideoScanModel.swift:770-785) on `!TestEnvironment.isTestHost`
   (still `rebuild` in-memory for test hosts that need search — just never
   touch the real plist; or redirect `defaultPersistenceURL()` under test).
2. `loadFromDisk`: reject a persisted index whose `recordCount` is
   grossly inconsistent with the live catalog (e.g. `recordCount == 0 &&
   !records.isEmpty`, or `< 50%` of records.count) — mirrors the version
   check that already exists.
3. Recovery is automatic (sanity check forces rebuild next launch).
Expected impact: 5.4 s → 0.06–0.14 s settled keystroke (the healthy-index
numbers). **This alone resolves the beachball as reported.**
Risk: none meaningful; behavior identical on healthy files.
Tests: poisoned-state isolation test (write a 0-record plist, assert
loadFromDisk returns false); assert test-host runs leave the real plist
untouched (mtime unchanged).

**PR B (P0, small) — one scan per settled query, not two.**
Compute the badge count from the table pass (count before the View-menu
chips narrow, preserving badge semantics) and publish {rows, hitCount}
together; delete the toolbar's duplicate debouncer+scan. Halves every
number in this doc. Risk: badge base must keep matching
`pfSearchBadgeBase` semantics — pin with a unit test.

**PR C (P1, medium) — off-main filtering, snapshot publish (the #104
VolumeStatusCache template).**
Constraint that shapes the design: **`VideoRecord` is a mutable
non-Sendable class** — do NOT hand `[VideoRecord]` to a background task
while the main actor mutates records. Ship Sendable data instead: the
haystack dictionary is a value-type `[String: String]` (O(1) CoW
snapshot), plus a small per-record Sendable sidecar (fullPath/id,
streamType, isPurged, isSetAside, precomputed years — or reuse the
existing `VideoRecordSnapshot` in CatalogSnapshot.swift). Background task
(generation-stamped, cancels stale predecessors) computes the matching
ID/path Set; the main actor applies one cheap
`records.filter { set.contains }` (~10–30 ms) and assigns `tableData`.
Also move the **launch rebuild** (5.97 s bench / 7.13 s real, currently
main-actor in init) onto the same background path — `buildHaystack` is
already `nonisolated` with a comment anticipating exactly this.
Expected impact: main-thread work per settled keystroke becomes the final
apply (~10–30 ms) for EVERY query class including "1990s"; launch
un-beachballs. Watch for: the Approachable-Concurrency trap
(`nonisolated async` runs on the caller's actor in this repo — use
`@concurrent` per the 3-incident memo); "Searching…" indicator should
reflect in-flight background work.

**PR D (P1, small) — precompute years per record.**
`pfYearsFromRecord` is 9.5 µs/record (char scan + per-record `Calendar`
init + 2 component extractions). Precompute `Set<Int>` years at index
build/update (persist alongside haystacks; additive), make yearRange a
set-membership test. Expected: 952 ms → ~20-40 ms per pass (bounded by
the O(n) walk), and with PR C it's off-main anyway. Keep
`pfYearsFromRecord` as the canonical reference; pin agreement in tests.

**PR E (P2, small, measure-first) — fast-path union instead of bail.**
`isFastPathEligible` already scans every indexed word to detect
needle-as-infix; instead of bailing, UNION the buckets of all words
containing the needle. For pure-alphanumeric needles this is exact (an
alnum needle cannot span a word boundary since words are maximal alnum
runs). Memoize per needle (existing memo slot). Turns the 58–72 ms linear
passes into ~1–30 ms. Only worth it if PR C's apply-pass floor still
bothers; measure first. Phrases/punctuated needles keep the linear path.

**Related but separate (#124):** A/V-default working set — measured 6–10×
here; layer it under PRs A–D.

**Out of scope, flagged:** header-click sort runs
`model.records.sort(using:)` + `tableData.sort(using:)` on main — 2.5 s
by filename at 100k (KeyPathComparator). Same off-main-snapshot template
applies; suggest a follow-up issue.

## The yardstick — run it before AND after

```
xcodebuild test -scheme VideoScan -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath <worktree>/DerivedData \
  -only-testing:VideoScanTests/CatalogSearchProfileBench
```

Grep stdout for `[#123-bench]`. The fix's before/after MUST use this
file unchanged (extend, don't edit, the query set).

## Scale-sensor spec (checklist dimension 2 + 5 — ships WITH the fix)

Extend `CatalogSearchProfileBench` (same corpus, Release) with budgets:

1. **Main-thread budget:** for every query in the bench set, the
   main-actor portion of a settled keystroke ≤ **50 ms** warm (post-PR-C
   that's the apply pass; pre-PR-C use settled_keystroke_ms). Fail the
   test above budget.
2. **Poison sensor:** persist a 0-record index file, load against a
   non-empty catalog → `loadFromDisk` MUST return false (correctness,
   not timing). Plus: running the suite MUST NOT modify the real
   `catalog.search-index.v1.plist` (compare mtime before/after — the
   isolation dimension).
3. **Agreement sensor:** healthy-index hits == empty-index-fallback hits
   for the cross-checked queries (already asserted in the bench).
4. **Launch budget:** index build for 100k records completes ≤ 8 s wall
   and runs off the main actor (spec for PR C; assert via the rebuild
   API's isolation, not sleep-polling).

## Corpus (what "Rick-shaped" means)

Measured from the real catalog.json (103,835 records, read-only,
2026-07-19): 78.1% audio-only / 12.2% V+A / 5.4% V-only / 4.2%
probe-failed; path length mean 137 p90 171; transcripts on 7.9% (mean
931 chars, median 24, max 84k); captions 11.0%; OCR 5.6%; people tags
0.63%; inferredRecordDate 9.7%; purged 0.3%; ~72% iTunes/Music paths.
The generator reproduces those proportions with deterministic seeded
content, unique fullPaths, and realistic vocabulary (100,307 indexed
words) including the "v1993…"/"christmas1995"-style words that defeat
the whole-word fast path exactly as real filenames do.

Fidelity note: real transcripts are natural language with a larger
vocabulary; the infix-eligibility cold scan (O(words)) is therefore
slightly under-weighted here. Cold ≈ warm in all runs, so it is not a
dominant term either way.
