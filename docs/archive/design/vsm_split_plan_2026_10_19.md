# Splitting `VideoScanModel` (GH #337): scope, slices, estimate

Plan agent (Fable), read-only, main @ fccceeaee, 2026-10-19. Saved by the Manager. **Nothing starts before Rick's go on the §6 decisions.**

## 1. Measured scope
- `Model/VideoScanModel.swift`: 1,857 lines, **90 `@Published`**, plus 115 other stored members (caches, tasks, snapshots, test hooks).
- **134 `extension VideoScanModel` files:** MediaOps 37, Catalog 28, Archive 20, Volumes 15, Media 11, People 6, ArchiveAngel 4, others 1–2 each.
- **73 view files bind the model** (65 `@EnvironmentObject`, 8 `@ObservedObject`); 43 of them read `records` directly.
- `records` is read in 472 app files and 698 test files, and 257 test files assign it. **It stays on the model as the facade**; every other store is pulled out around it.
- The `records` didSet fans out to 9 callees (VideoScanModel.swift:18-41). The comment at :23-29 records a real data-loss mode: a stale path index lost a dossier write-back. **Index invalidation must stay synchronous.**
- Precedent: `MediaFileOperationsCenter`, `PersonFinderModel` and `DashboardState` are already separate objects injected through the environment. The app has no `@Observable` classes today.

## 2. Mechanism (behaviour-preserving)
- Each slice moves its members into a new `@Observable @MainActor final class XStore`, which the model holds as `let x = XStore()`.
- The old names stay on the model as computed forwarders. In C++ terms: a pimpl per feature with inline forwarding accessors.
- So all 134 extension files and ~1,000 test files compile unchanged, and the 73 views keep working.
- Moving each view onto its store directly is a separate, optional PR per store, done later.
- Copy the shape of the exemplar: `VideoScanCore/.../Commit/CatalogCommit.swift` (outcomes as enums, value state in structs).

## 3. Slices
| # | Slice | Files | Data-loss path | Codex | Effort |
|---|---|---|---|---|---|
| 0 | Guard rails: sensor (extension count ≤ 134, `@Published` ≤ 90, numbers only fall); measure full-suite wall time | +1 test | no | no | 0.5 night |
| 1 | PreviewService (Media/ +Thumbnail, +Filmstrip, +PreviewSweep) | 3 | no | no | 1 night |
| 2 | ScanStore (Volumes/: scanTargets, isScanning, volume caches, rename migration, scanOptions, perfSettings) | 15 (+58 readers) | **yes** (ScanMerge, DeleteScanTarget, Retire) | yes | 2 nights |
| 3 | RelocateQueue | 3 | **yes** (moves media) | yes | 1 night |
| 4 | NavigationStore (18 pending/sheet props) | 0 ext | no | no | 1 night, after Rick's folder UI settles |
| 5 | ArchiveStore (masterArchive, promote state, audit revision) | 20 | **yes** | yes | 2–3 nights |
| 6 | DuplicateJobs (correlate, analyze, delete duplicates, combine) | 11 | **yes** | yes | 2 nights; Q4 first |
| 7 | Change bus replacing the `records` didSet (a synchronous subscriber list, not AsyncStream) | model | **yes** | yes | 1 night, after 1, 2, 5 |
| 8 | RemovalStore (Cleanup, purge, junk, prune) | 14 | **yes** | yes | 2 nights; **blocked on Q4** |
| 9 | CatalogStore (the `records` owner) + People/Events/Steward | ~40 | **yes** | yes | 4+ nights, last |
| — | Activity enum (flag soup) | — | behaviour-*changing* | — | parked: needs a table of flag combinations first |

**Parallel-safe pairs:** 1 ∥ 2, 2 ∥ 3, 5 ∥ 6. **Serial:** 0 first, 7 after 1/2/5, 9 last. At most two move-slices in flight at once; the third worktree is for tests.

**Resources:**
- Claude worktree agents do every move and proof run.
- codex gets one bundled pass after 2+3, one after 5, and one after 7.
- qwen triages each night's diff and log in the morning.
- CC cloud drafts the move manifests only (it can't build the app).
- The M5 Ultra, from 10/27, takes slices 5, 6 and 9.

## 4. Estimate
- **By Fri 10/23: not the whole split.** The coherent, achievable stopping point:
  - slice 0 (Mon), slice 1 (Tue), slice 2 (Wed–Thu, codex Fri), plus slice 3 if there's room;
  - that moves ~21 of 134 extensions and ~25 of 90 properties, puts the sensors in force, and proves the pattern on one no-risk store and one data-risk store.
  - Confidence: moderate-high for 0–1, moderate for 2.
- **Whole programme (0–9, without the Activity enum and RemovalStore until Q4):** ~14–18 agent-nights. That's **3–4 calendar weeks, finishing around 11/13**, with moderate confidence. The biggest unknown is the full-suite wall time per night, which slice 0 measures.

## 5. Guard rails
- **Standing rule:** no new `extension VideoScanModel` and no new `@Published` on the model. The sensor enforces this in CI.
- **Day/night protocol:**
  - Daytime work doesn't edit the model's property declarations, and merges to main by evening.
  - Night slices start by rebasing and touch only their folder plus the model file.
  - The Catalog and MediaOps slices wait for the daytime UI burst to end.
- **Rollback:** one squash-merge per slice; revert the merge commit.

## 6. Rick's decisions (before slice 1)
1. **The forwarder approach** (callers untouched) instead of a hard cut (73 views + ~1,000 tests). Recommended.
2. **`@Observable` for the new stores**, an architecture change. macOS 26 target, mixing with ObservableObject is supported, and settings keep their explicit `save()` because of the didSet gotcha.
3. **Threading: no change.** Every store is `@MainActor`.
4. **Change bus:** synchronous inline calls, not a queue.
5. **The Activity enum** is outside this programme.
6. **Retrospective Q4 (removal lanes) and Q8 (Angel)** must be decided before slices 6 and 8.

## 7. Interaction with "JSON gone by Friday"
Added by the Manager. The JSON retirement (step G plus Import removal) touches the ~150 save-wrapper sites, and many of them are in model extensions. It runs as its own track; see `docs/reviews/cutover_acceptance_audit_2026_10_19.md`. Merges are sequenced so the two tracks never touch the same files in the same night.
