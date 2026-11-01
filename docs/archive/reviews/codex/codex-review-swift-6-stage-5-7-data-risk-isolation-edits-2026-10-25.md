# Codex review — Swift 6 stage 5-7 data-risk isolation edits

- Range: `a6b38cf28..10fe1b12f`
- Credits spent: unavailable
- Tokens: 127864
- Finding count: 0
- Verdict: merge — no regression found in `a6b38cf28..10fe1b12f` against the four scoped invariants.
- Run: 2026-10-25T18:50:53Z (cycle #137, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 0  
Verdict: merge — no regression found in `a6b38cf28..10fe1b12f` against the four scoped invariants.

- **Isolation:** no edit moves catalog or archive mutations into a second isolation context. All three `runLane` methods remain main-actor isolated. (`docs/DESIGN.md` §§1, 4, 7.)
- **Trash refusal:** the offline predicate’s body, synchronous invocation, refusal precedence, and checks before disk operations remain unchanged. (§§3, 6.)
- **Ordering:** START precedes lane work; task-group completion precedes final saves and OUTCOME. Notification placement and authorization checks are unchanged. Per-lane order is preserved; cross-lane order was never guaranteed. (§6.)
- **Relay:** the off-main guard still returns `nil` before accessing committers. The synchronous main-thread path passes the same live object to identity-based ownership checks. (§§1, 7.)

Each scoped file:

| File | Result |
|---|---|
| `Archive/ArchiveLockJob.swift` | read, no findings |
| `MediaOps/VideoScanModel+RelocateQueue.swift` | read, no findings |
| `MediaOps/VideoScanModel+TrashSelection.swift` | read, no findings |
| `Catalog/CatalogMarkerRelay.swift` | read, no findings |
| `MediaOps/VerifyAudioSheet.swift` | read, no findings |
| `MediaOps/AudioFingerprintBackfillJob.swift` | read, no findings |
| `MediaOps/CatalogAuditJob.swift` | read, no findings |
| `MediaOps/FullHashBackfillJob.swift` | read, no findings |

Validation limitation: my sensor attempt executed **0 tests**; the read-only sandbox denied opening its log for writing. The commit reports **1,245 Swift Testing + 8 XCTest, 0 failures**, and **568 sensors GREEN**; these were not independently rerun. No files changed; no broader implementation review undertaken.

## Brief

# Codex review brief — Swift 6 stages 5–7: isolation edits in data-risk files

**Workflow in one sentence (the user's words):** "we need to be using the latest swift 6 … the compiler is proving the absence of data races, so every fix must keep the proof honest" — this slice fixes strict-concurrency warnings; nothing a user does changes.

**Range:** `a6b38cf28..10fe1b12f` on branch `swift6/stage567-media-catalog-tests` · **Worktree:** `/Users/rickb/dev/VideoScan-wt/swift6-B`

**In scope (read these and their direct callers; nothing else):**
- `VideoScan/VideoScan/Archive/ArchiveLockJob.swift` — `title` became `nonisolated static let` (an immutable String the nonisolated `lockOne` passes as the index-lock holder name). Nothing else changed.
- `VideoScan/VideoScan/MediaOps/VideoScanModel+RelocateQueue.swift` — `postCompletionNotification(for:)`: the `UNUserNotificationCenter` completion no longer captures `center`; it calls `UNUserNotificationCenter.current().add(…)`. Nothing else changed.
- `VideoScan/VideoScan/MediaOps/VideoScanModel+TrashSelection.swift` — `isRecordOnOfflineVolume` became `nonisolated static` (it reads `isExternalVolumePath` and `VolumeReachability.isReachable`, both nonisolated). It is the default `isOffline` predicate of `catalogTrashPlan(for:isOffline:)`. Nothing else changed.
- `VideoScan/VideoScan/Catalog/CatalogMarkerRelay.swift` — `markerWillChange`: one `nonisolated(unsafe) let record = record` under the existing `Thread.isMainThread` guard, before the existing `MainActor.assumeIsolated`. The committer's identity-based `owns` still receives the live object. Nothing else changed.
- `VideoScan/VideoScan/MediaOps/VerifyAudioSheet.swift` — `VerifyAudioDismissHandoff.perform`: `action` is typed `@MainActor () -> Void`; the default scheduler is `Task { @MainActor in sleep 200 ms; action() }` instead of `DispatchQueue.main.asyncAfter`. Callers unchanged.
- `VideoScan/VideoScan/MediaOps/{AudioFingerprintBackfillJob,CatalogAuditJob,FullHashBackfillJob}.swift` — `group.addTask { @MainActor in await self.runLane(…) }` → `group.addTask { await self.runLane(…) }` (`runLane` is main-actor isolated; the await hops).

**Invariants to attack** (one line each; cite `docs/DESIGN.md` §):
1. No catalog or archive write reaches disk from a second isolation context: show a path where any of the edits above lets a marker change, an index write, a relocate record, or a trash plan run off the main actor where it ran on it before.
2. The trash proof still runs before unlink: `catalogTrashPlan(for:)` with the nonisolated `isRecordOnOfflineVolume` default must refuse exactly the rows it refused before (offline volume → held, never trashed).
3. Ordering of START/OUTCOME lines is unchanged: the three backfill jobs' lanes still run through `runLane` on the main actor in the same order; `postCompletionNotification` still posts once per job after OUTCOME.
4. `CatalogMarkerRelay.markerWillChange`: the opt-out only widens what the compiler accepts, not what runs — a caller off the main thread still gets `nil` from the guard and never touches the committer.

**Evidence already run:** clean build-for-testing with the sensor lane's flags, 0 warnings in the touched modules; related suites (see commit message for counts); `scripts/run_sensors.sh` GREEN (counts in the commit message).

**Known and accepted (do not report):** the `nonisolated(unsafe) let` in the relay is a documented opt-out (the relay is nonisolated by design so the nonisolated doors `stampRemoval`/`revertRemoval` can ask; making it `@MainActor` cascades through ~15 call sites including off-main caption work) — accepted by the stage-5 brief; HallieWebAccess/HallieWebBridge statics are another worker's slice and are not touched here.

**Output contract:**
```
Credits spent: <amount> | Finding count: <N>
Verdict: merge | fix | block — <one sentence>
```
Then findings ranked by data-loss risk, each with `file:line`, a reproduction, and a RED test where possible. For every in-scope file with nothing to report write "read, no findings." Do not explore outside the files above unless a finding requires it, and say so.
