Brief: N1008-D-MediaVolumeGateHold | Source: main@e7e482f7 | Wall clock: ~7 (container clock) | Files read: 26
Finding count: 3 (REAL 2 / NEEDS-MAC 1 / NOISE 0)
Verdict: The move is worth doing and mostly behaviour-neutral, but the shared hold is not a drop-in for every job yet: it needs an observable waiting state, a scoped no-lend form for Promote / Verify Archive Copies / Pair Compare / Compare Footage / Backfill, and a run-task "step aside" form for Bind Fixity. Add those (with tests on the hold itself) before moving any job, then move the jobs lowest data risk first, Promote last.

## Scope and method

- Theme D, steps 0–4, over the per-volume gate / pause code in the MFO jobs, measured against
  `MediaVolumeGateHold` (VideoScan/VideoScan/MediaOps/CheckMedia/MediaVolumeGateHold.swift, added in `cc96861f`, merged in `df616324`).
- Callees I followed to settle points: `PausableGatePermit` (VideoScanCore), `AsyncSemaphore.withPermit`,
  `MediaVolumeGate` / `VolumeGateBoard` / `MediaFileOperationsCenter.gatePlan` (MediaFileOperations.swift 652–712, 1447–1476),
  the job row's subtitle rendering (MediaFileOperationsWindow.swift 543), and `CheckMediaJob` (the hold's only user today).
- **Count: the row says 7. There are 9.** Seven jobs use `PausableGatePermit` directly (Verify Audio, Verify Video,
  Rebuild Audio, Perceptual Fingerprint Backfill, Promote, Verify Archive Copies, Bind Fixity). Two more (Pair Compare,
  Compare Footage) still use the older recursive `semaphore.withPermit` form. The hold's own header says "VerifyAudioJob,
  VerifyVideoJob and five other jobs", which matches the 7. The plan covers all 9 and marks the two `withPermit` jobs as
  optional, though cheap.
- Step 0 (complexity): `ci/baselines/complexity_debt.json` lists **none** of the gate functions as offenders. The
  in-scope offenders are elsewhere in the same files: `RebuildAudioJob.runRebuild` (CCN 27, 138 lines),
  `VerifyArchiveCopiesJob.verifyOne` (20/99), `BindFixityToVolumeJob.run` (16/52),
  `PromoteToArchiveJob.copyOrAdopt` (17/84) and `.finishPublished` (17/123, in +Steps.swift). VerifyArchiveCopiesJob.swift
  is 1,123 lines (over 800). The metrics branch (nightly 2026-10-07, `4b79bbbb`) shows `debt_new: 0`. So this refactor is
  about duplicated logic (step 2), not CCN. It removes about 60–110 lines per lending job and does not touch any offender.
- Gate order: every production caller builds its gates with `gatePlan(forPaths:)`, which dedupes and **sorts by root**
  (1475). That includes CheckMedia's `gatesFor` (1417), Backfill's (494), Promote's sources plus archive root (+Promote.swift 30)
  and Verify Archive Copies' archive root (1106). No copy acquires in unsorted order. The hold itself does **not** sort.
  It trusts its caller, as every copy does (see the design section).

## The shared hold, in one paragraph

`MediaVolumeGateHold` is a `@MainActor` class that owns the job's `PausableGatePermit`s in acquisition order, plus one
serial op chain:
- `acquire(_:isPaused:) async -> Bool` takes the gates in order. If a pause lands while it waits for a gate, that gate is
  lent straight back and acquire holds until the pause ends (codex #295). It returns false on cancel after closing everything.
- `lend()` gives every slot back, on the chain.
- `reacquire(then:)` re-holds every slot on the chain, then calls back `true` only when all of them are `.held` again.
- `close()` releases in reverse order and does not wait on the chain.
- `waiting: (label, root)?` is set while queued.

The board claim/clear calls are inside the hold. Finishing (Cancelled / Failed) is left to the caller.

## Copy → difference table

"Same" means the same calls in the same order as the hold. Line ranges are on main@e7e482f7.

| # | Job / file:lines | Acquire order | Cancel while queued | Pause semantics | Board claim/clear | Waiting label | Release on every exit | Gate held across data step | Behaviour change if moved onto the hold | Safe? |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | **VerifyAudioJob** MediaOps/VerifyAudioJob.swift 83–135 (chain, pause, resume), 144–156 (label/subtitle), 206–276 (run, close) | gatePlan order (sorted) | closes held, `finishCancelled` | SIGSTOP then lend on chain; resume re-holds all then SIGCONT; late-acquire-while-paused lends and holds (#295) | same | `@Published waitingForVolumeLabel` + root; **not cleared on the paused→cancel path (F1)** | yes: catch, paused-cancel, normal end | verdict write happens while held (catalog metadata only) | (a) waiting label cleared on paused-cancel, which fixes F1; (b) waiting **stops being published** unless the hold gains a change hook (F3) | (a) yes; (b) **no**: needs the extension first |
| 2 | **VerifyVideoJob** MediaOps/VerifyVideoJob.swift 52–100, 111–125, 163–216 | same | same | same (verbatim copy) | same | same, **F1 too** | yes | verdict write | same as #1 | same as #1. Note: `startVerifyVideo` has **no production caller** (grep). Check Media replaced the verb, so retiring the job is an option (Rick's call) |
| 3 | **RebuildAudioJob** MediaOps/RebuildAudioJob.swift 221–265, 336–404 | same | same; `finishCancelled` defers to a recorded stall reason | same (verbatim) | same | same, **F1 too** | yes | ffmpeg writes a new partial file on the source volume, then renames it next to the original. The gate is held but lent while paused (child SIGSTOPped) | same as #1; stall/terminalCause logic stays in the job | yes, after the extension |
| 4 | **PerceptualFingerprintBackfillJob** MediaOps/PerceptualFingerprintBackfillJob.swift 165–175 (pause/resume), 240–251, 300–324 | sorted, per file | releases held, returns nil; also releases if `stopped` right after acquire (312) | **cooperative, between files only; never lends.** A pause during a file keeps the gate until that file's pass ends | claim, clear on release; **name is the static title** | plain `subtitleText = "Waiting for X…"` (no holder name) | yes | stores derived fingerprints, checkpointed | must pass `isPaused: { false }`. Passing the real flag would lend in acquire, and `resume()` never calls `reacquire`, so the file would run **without a slot**. Subtitle gains "— in use by …" | yes **only** with `isPaused: { false }` or the scoped form |
| 5 | **PromoteToArchiveJob** Archive/PromoteToArchiveJob.swift 198–200, 241–271 | sorted; source roots + archive root deduped | releases, `finishCancelled` | **no pause (`canPause` defaults false); gates held for the whole run** | claim "Promote …", clear | `@Published` label + root | yes: catch, normal end (run's internal returns all come back to 262) | **yes: copy, verify, publish, ledger.** Must never lose the archive gate mid-file | none, if it uses a form with **no lend at all** | yes, with the scoped form. With the full class, a future pause wiring could lend the archive gate mid-copy |
| 6 | **VerifyArchiveCopiesJob** Archive/VerifyArchiveCopiesJob.swift 327–329, 362–392 | archive root only | same as Promote | no pause; held for whole run | claim "Verify Archive Copies", clear | `@Published` label + root | yes | yes: fixity restore / clear writes | none with the scoped form | yes |
| 7 | **BindFixityToVolumeJob** Archive/BindFixityToVolumeJob.swift 75–76, 147–159, 165–197, call sites 232, 246, 253, 294 | sorted (one scope root) | `acquireGates` returns false; caller `releaseGates`, `finish(cancelled:)` | **cooperative pause on the run task:** `control.setPaused` aborts the current file; `waitOutPause` lends **on the run task (no chain)**, waits, re-holds, checks `.held`, then **restarts the file**. No SIGSTOP | **claim on acquire only; lend does not clear, re-hold does not claim (F2)** | plain `subtitleText` (no holder name) | yes: acquire fail, offline-volume stop, failSave, normal end | fixity binding writes; pause restarts the file so no stale read is reused | needs a run-task "step aside" (lend → wait → re-hold → claim). The chain-based `lend()`/`reacquire(then:)` does not fit. Fixes F2 | yes, after the extension |
| 8 | **PairCompareJob** MediaOps/PairCompareJob.swift 85–90, 139–180 | sorted | `withPermit` throws, label nil; outer permits unwind structurally | no pause | claim/clear inside `withPermit` body (clear **before** signal) | `@Published` label + root | yes (structured) | read-only | board clear moves to after signal (cosmetic). Otherwise none | yes |
| 9 | **FootageSpectrumJob** MediaOps/FootageSpectrumJob.swift 152–153, 256–281 | sorted | same as #8; run() ends Cancelled if still active | no pause | same as #8 | plain vars + manual `objectWillChange.send()` | yes | read-only (writes its own cache folder) | same as #8 | yes |
| — | **CheckMediaJob** (the reference user) MediaOps/CheckMedia/CheckMediaJob.swift 127–162 | sorted, per file | `acquire` false → break → finish | SIGSTOP-style lend/reacquire through the hold | inside hold | **`hold.waiting` is not observable (F3)** | yes | report-card write | — | — |

### Differences that are real risk when moving

1. **Pause model: three kinds, one API.** SIGSTOP + lend on a chain (Verify Audio, Verify Video, Rebuild, Check Media);
   cooperative pause between files, never lending (Backfill); cooperative pause that lends on the run task and restarts the file
   (Bind). No pause at all (Promote, Verify Archive Copies, Pair Compare, Compare Footage). The hold today only covers the first.
2. **Holding across the data step.** Promote and Verify Archive Copies hold for the whole run and must keep holding. The
   safest guarantee is one the type system gives: their form must have no `lend`.
3. **Observability.** Six jobs publish their waiting label (`@Published` or a manual send). The hold's `waiting` is a plain
   property on a non-observable class, so moving those jobs as-is would regress the 2026-08-07 "waiting-row honesty" fix.
4. **Actor reentrancy.** Every resume path re-checks phase after the `await` (`currentPhase == .held`). Bind restarts the file
   rather than reuse anything read before the pause. Verify / Rebuild resume a SIGSTOPped child that holds no state across
   the pause. None of the jobs reads state before acquire and trusts it after. The only pre-acquire reads are the immutable
   `record` / `plan`. Promote's preflight runs **after** acquire (`run()` 282+), which is right. Keep it there.

## Findings

### N1008-D-MediaVolumeGateHold-F1 — P3 — REAL
**Symbol:** `VerifyAudioJob.runHoldingGates` (MediaOps/VerifyAudioJob.swift 234–249). Same code in
`VerifyVideoJob.runHoldingGates` (VerifyVideoJob.swift 182–197) and `RebuildAudioJob.runHoldingGates` (RebuildAudioJob.swift 363–379).
**Scenario:** The job queues on gate G (held by another job). The user pauses while it is queued. The other job releases G,
so the acquire completes on a paused job and enters the #295 hold loop with `waitingForVolumeLabel == G.label` still set.
The user then presses Stop. The loop exits on `Task.isCancelled`, closes the permits and calls `finishCancelled()`, which sets
`subtitleText = "Cancelled"` but **not** `waitingForVolumeLabel = nil`. The `subtitle` getter checks the label first
(VerifyAudioJob 150–153), and the row renders `job.subtitle` unconditionally (MediaFileOperationsWindow.swift 543). So the
finished, cancelled row reads "Waiting for G…" forever. The catch path (253–255) does clear it, so only this path leaks.
UI-only: no data effect. The shared hold clears `waiting` on this path (MediaVolumeGateHold.swift 70), so the migration fixes it.
**Smallest pinning test (fails today):** Copy the recipe from `VerifyAudioJobTests.pauseDuringLateGateAcquisitionLendsThePermitAndHoldsWork`:
external hold on s2, start, `pause()`, `s2.signal()`, sleep 200 ms, then `job.cancel()`, `await job.task?.value`, and
`#expect(job.state == .cancelled && job.subtitle == "Cancelled")`. Repeat for VerifyVideoJob and RebuildAudioJob.

### N1008-D-MediaVolumeGateHold-F2 — P3 — REAL
**Symbol:** `BindFixityToVolumeJob.waitOutPause` (Archive/BindFixityToVolumeJob.swift 187–197).
**Scenario:** The lend loop (`releaseForPause`) never calls `VolumeGateBoard.shared.clear`, and the re-hold loop never calls
`claim`. Every other lending path does both (VerifyAudio 103–106 / 122–128, the hold 85/95/109). Take a one-slot (HDD) volume:
1. Bind pauses and lends the slot, but the board still names Bind.
2. Job B, queued on that volume, gets the slot and claims the board. B finishes and clears its own entry, so the board is now empty.
3. Bind resumes and re-holds the slot **without claiming**.
4. Job C now queues on that volume. Its row reads "Waiting for X…" with no holder: the unexplained wait the board exists to prevent.

Also, while Bind is paused and before B claims, the board names a job that does not hold the slot. UI-only: the semaphore
stays the authority, so admission is correct.
**Smallest pinning test:** Copy `FixityStampVolumeIdentityTests.jobPauseGivesWayAndResumeFinishes`, but pass
`gates: [MediaVolumeGate(root: "/Volumes/T", label: "T", semaphore: AsyncSemaphore(limit: 1))]`. After `pause(); start()` and
300 ms, `#expect(VolumeGateBoard.shared.holders["/Volumes/T"]?.jobID != job.id)` (fails today). Also check that a probe
`PausableGatePermit` on the same semaphore reaches `.held`, which pins the lend that already works.

### N1008-D-MediaVolumeGateHold-F3 — P3 — NEEDS-MAC
**Symbol:** `MediaVolumeGateHold.waiting` (MediaVolumeGateHold.swift 32), read by `CheckMediaJob.subtitle` (CheckMediaJob.swift 106).
**Scenario:** The hold is not an `ObservableObject`, and `waiting` is a plain `private(set) var`. When Check Media starts file N
and queues behind another job's gate, `run()` sets `self.hold` (not published) and suspends in `acquire`. Nothing `@Published`
changes, so the row's `onReceive(job.objectWillChange)` never fires and the row keeps its last subtitle: "Waiting to start…" for
file 1, or file N−1's last step line. It does not show "Waiting for X — in use by Y…". Every copy publishes its label
(`@Published waitingForVolumeLabel`, or Compare Footage's manual `objectWillChange.send()`, FootageSpectrumJob 268).
I class it NEEDS-MAC because I did not prove that no other publisher re-renders the row while queued (the window has no
TimelineView or Timer per grep, but parent re-renders were not traced).
This is also the **blocker for the migration**: moving the six publishing jobs onto the hold as it is would regress all of them.
**Smallest pinning test:** One-slot semaphore held by a probe. A `CheckMediaJob` with `gatesFor` returning that gate and a
`quickRunner` stub. Subscribe a counter to `job.objectWillChange`, start, sleep 200 ms, then
`#expect(job.subtitle.hasPrefix("Waiting for"))` and `#expect(counter > 0 after the subtitle became "Waiting for…")`.
On the Mac, confirm visually in the MFO window.

Considered and dropped (did not meet the bar):
- A resume that lands while CheckMedia's per-file `hold.close()` is mid-loop: `reacquire` sees `.closed` and reports false, so
  the job stays paused until a second Resume. The window is a few actor hops after the child has already exited, and a second
  click recovers it. This is a design note below, not a finding.
- Unsorted acquisition: no production caller passes unsorted gates.
- A missing release on some exit path: every path in all 9 jobs reaches close/release. I checked Bind's four `releaseGates`
  sites and Promote / Verify Archive Copies' single tail.

## Step-4 design

**Concept: a scoped, ordered lease on volume read slots, owned by one object.** It is RAII in C++ terms. In Swift terms it is
the `with…` structured-scope idiom (`withTaskGroup`, `withTaskCancellationHandler`, `AsyncSemaphore.withPermit`) for jobs that
never lend, plus a `@MainActor` reference type that owns mutable permit state and serializes lend/re-hold for jobs that do.

Canonical sources:
- *The Swift Programming Language*, Concurrency ("Actors", "Task Cancellation"): main-actor isolation, cancellation as a
  cooperative check.
- SE-0304 Structured Concurrency (the `with…` scope that cannot leak its resource).
- SE-0306 Actors, on reentrancy: re-check state after every `await`, which `PausableGatePermit`'s transitional phases already do.
- Swift API Design Guidelines: name methods by their effect at the use site (`lend`, `reacquire`, `close`); prefer an
  argument label that reads as a phrase (`stepAside(while:)`).

**Before:** nine copies, three shapes:
```swift
// lending copies (VerifyAudio/VerifyVideo/Rebuild)
private var gateOpsChain: Task<Void, Never>?
private var gatePermits: [(gate: MediaVolumeGate, permit: PausableGatePermit)]
@Published private(set) var waitingForVolumeLabel: String?
private func runHoldingGates(_ remaining: ArraySlice<MediaVolumeGate>) async
private func closeGatePermits() async
// whole-run copies (Promote/VerifyArchive/Bind/Backfill)
private var heldGates: [(gate: MediaVolumeGate, permit: PausableGatePermit)]
private func runHoldingGates() async / acquireGates() async -> Bool
private func releaseGates() async
// structured copies (PairCompare/Footage)
private func runHoldingGates(_ remaining: ArraySlice<MediaVolumeGate>) async  // recursive withPermit
```

**After:** one type, three entry points. The existing four methods stay unchanged.
```swift
@MainActor
final class MediaVolumeGateHold {
    init(jobID: UUID, holderName: String,
         onWaitingChange: @escaping @MainActor () -> Void = {})   // F3: job passes { [weak self] in self?.objectWillChange.send() }

    private(set) var waiting: (label: String, root: String)?      // didSet { onWaitingChange() }

    // Lending, child SIGSTOPped (VerifyAudio, VerifyVideo, Rebuild, CheckMedia) — unchanged
    func acquire(_ gates: [MediaVolumeGate], isPaused: @escaping @MainActor () -> Bool) async -> Bool
    func lend()
    func reacquire(then: @escaping @MainActor (Bool) -> Void)
    func close() async

    // Lending, cooperative on the run task (Bind) — NEW
    /// Lend every slot (board cleared), wait while `isPaused`, re-hold every slot
    /// (board re-claimed). False when cancelled or a slot could not be re-held.
    func stepAside(while isPaused: @escaping @MainActor () -> Bool) async -> Bool
}

extension MediaVolumeGateHold {
    // Never lends (Promote, VerifyArchiveCopies, PairCompare, Footage, Backfill per file) — NEW
    /// Holds every gate for the body, releases on every exit. nil = cancelled while queued
    /// (nothing ran, nothing held). The body cannot reach `lend`.
    static func withHeld<T>(_ gates: [MediaVolumeGate], jobID: UUID, holderName: String,
                            onWaitingChange: @escaping @MainActor () -> Void = {},
                            _ body: @MainActor () async -> T) async -> T?
}
```
- `withHeld` is `acquire(gates, isPaused: { false })`, then `defer`-style `close()` after `body`. Swift has no async `defer`,
  so write it as `let r = await body(); await hold.close(); return r`. The body is non-throwing in every whole-run job, so
  there is no exit that skips close. Promote / Verify Archive Copies get a type-level guarantee that no future pause wiring
  can lend the archive gate mid-file.
- Keep **one** owner of slot order: either have `acquire` assert `gates == gates.sorted { $0.root < $1.root }` (debug
  `assert`, no behaviour change), or introduce `struct MediaVolumeGatePlan { let gates: [MediaVolumeGate] }` whose only
  initializer is `gatePlan(forPaths:)`. The second is the cleaner value-type design, but it touches every init. The assert is enough.
- `reacquire` on a hold whose permits are all `.closed` should call `then(true)` (nothing left to hold). That closes the
  resume-during-close design note for multi-file jobs. It needs a pin test, and it is a behaviour change for CheckMedia only.
- Rejected shapes: moving the copies into a protocol extension with `var gatePermits { get set }` (widens access, so the state
  stays spread across nine owners), or a closure table keyed by pause style (hides the three models instead of naming them).

Size of the hold extension: **M** (about 60 lines plus a new `MediaVolumeGateHoldTests`).

## Ranked plan (lowest data risk first)

**Step 0 (prerequisite, M): extend and pin the hold itself.** No job moves until this lands. New `MediaVolumeGateHoldTests`,
porting the existing job-level recipes to the type:
- (a) acquires in order and queues behind a held slot;
- (b) cancel while queued on gate 2 returns false, a probe can take gate 1, and `waiting == nil`;
- (c) a late acquire while paused lends and holds (the codex #295 recipe from VerifyAudioJobTests 354);
- (d) `reacquire` reports false while a probe holds the slot, then true after release;
- (e) close balance: after `close()`, `limit` probes all reach `.held`;
- (f) board: claim by job id on acquire, cleared on lend and close, re-claimed on reacquire;
- (g) `onWaitingChange` fires on queue and on clear (F3);
- (h) `withHeld` returns nil on cancel-while-queued and runs no body;
- (i) `stepAside` lends, waits, re-holds and re-claims.

The permit-level suite (`PausableGatePermitTests`, 6 tests) stays as the base.

| Order | Job | Behaviour-preserving steps | Pinning tests that must exist BEFORE | Risk | Size |
|---|---|---|---|---|---|
| 1 | **PairCompareJob** (read-only, no pause) | Replace the recursive `runHoldingGates` with `withHeld(gates…) { await runComparator() }`. A nil result is the cancel-while-queued path (keep the log line). Keep `@Published waitingForVolumeLabel` as a mirror set from `onWaitingChange`, or have `subtitle` read the hold | **None exists with real gates** (all use `gates: []`: MediaFileOperationsTests 244, MFOCancelledStateTests 103). Add: queued behind a probe-held gate → subtitle "Waiting for…", runs after release; cancel while queued → `.cancelled` and the probe can re-take the slot | Low | S |
| 2 | **FootageSpectrumJob** (read-only) | Same as #1. Keep `objectWillChange.send()` through `onWaitingChange`; keep "if still active after the gates, finish Cancelled" | Same two tests (existing FootageSpectrumTests 510 uses `gates: []`) | Low | S |
| 3 | **VerifyVideoJob** (verdict metadata) | **First ask Rick whether to retire it.** It has no production dispatcher since Check Media. If it stays: the CheckMedia shape, one hold per run; delete chain, permits, label, close; `pause` → `hold.lend()`; `resume` → `hold.reacquire { allHeld in … }` | Existing: `verdictPersistsToReplacementRecordWithSameID` (gated), `cancelWhileQueuedEndsCancelledAndPersistsNothing`, `pausableLikeVerifyAudio`. Add: the #295 late-acquire port, plus F1 | Low | S |
| 4 | **VerifyAudioJob** (verdict metadata; Angel uses it) | As #3 | Existing: `jobWaitsForTheVolumeGateAndRunsWhenReleased`, `pauseDuringLateGateAcquisitionLendsThePermitAndHoldsWork`, `fourJobsOnAOneSlotGateAllComplete`, `VerifyAudioJobDeepTests.hddClassedJobsAcquireInDispatchOrderAndNeverOverlap` / `ssdClassedJobsRunConcurrentlyWithNoGate`. Add: F1 pin; board names this job while it runs and is cleared while paused | Low | S |
| 5 | **PerceptualFingerprintBackfillJob** (derived data, per file) | `fingerprintOne` → `withHeld(gatesFor(path)…) { stopped ? nil : await watchedPass(…) }`. Keep the "stopped right after acquire → release, nil" check inside the body. **Never** pass the pause flag. The subtitle gains the holder name (call it out to Rick as the only visible change) | Existing: `pauseFeedback`, `stopEndsCancelled` (both ungated). Add: gated file waits behind a probe; Stop while queued → Cancelled, saved fingerprints kept; **pause during a file does not lend** (a probe stays blocked until the file ends), which pins the `isPaused:{false}` choice | Low–Med | S |
| 6 | **RebuildAudioJob** (writes a new file on the source volume) | As #4. Leave `terminalCause` / stall / `finishCancelled` untouched; only the gate lines move | Existing: MFOCancelledStateTests "rebuild audio: injected ffmpeg exits 255 on SIGTERM after Stop → Cancelled" and "rebuild: stall then Stop → Failed…" (ungated). Add gated versions: cancel while queued → no partial file created; pause → probe takes the slot; resume queues behind the probe and the injected ffmpeg is not continued until the release (NEEDS-MAC: ffmpeg shim); F1 pin | Med | S–M |
| 7 | **BindFixityToVolumeJob** (fixity bindings) | `acquireGates` / `releaseGates` → one hold. `waitOutPause` → `hold.stepAside(while: { self.isPausedValue && !self.stopped })`. Keep the file-restart loop and the four release sites as `hold.close()`. Fixes F2 | Existing: `jobPauseGivesWayAndResumeFinishes` (ungated). Add: gated pause → the probe reaches `.held` and the board is cleared (F2); resume queues behind the probe and binds nothing until release; Stop while paused → saved bindings kept, slot balance; offline-volume stop releases | Med (fixity record) | M |
| 8 | **VerifyArchiveCopiesJob** (archive fixity restore/clear) | `runHoldingGates` → `withHeld([archiveGate]…) { await run() }`, nil → `finishCancelled()`. No lend reachable | Existing tests are all ungated (VerifyArchiveCopiesTests 79–197). Add: queued behind a held archive gate → no file read and no fixity written until release; cancel while queued → `.cancelled`, nothing written; **gate held for the whole run** (a probe stays blocked during a run with a seam that suspends mid-verify) | Med–High | S |
| 9 | **PromoteToArchiveJob** (archive copy + ledger), last | As #8: `withHeld(gates…) { await run() }`. Preflight stays inside the body (after acquire) | Existing promote tests are ungated. Add: queued behind a held **archive** gate → nothing copied, ledger untouched, manifest unchanged; cancel while queued → same; gate held across copy → verify → publish (probe blocked through a seam); a source sensor that PromoteToArchiveJob*.swift contains no `lend(` / `reacquire` / `releaseForPause`; a `gatePlan` test (sources plus archive root, deduped, sorted), which **has no test today** | High (data path; per the spend policy this is the one that earns a codex pass, bundled with #8) | S |

Backlog (one line each):
- Retire `VerifyVideoJob` / `startVerifyVideo` if Rick agrees (dead dispatcher).
- `VolumeGateBoard` changes are never forwarded to waiting rows, despite its header ("gated jobs forward `objectWillChange`"); grep finds no subscriber. Separate from this move.
- VerifyArchiveCopiesJob.swift is 1,123 lines and `verifyOne` is CCN 20 / 99 lines: a separate D row.

## Not covered

- I did not build or run anything (Linux, no Xcode). All test names above were read from source, not run.
- The AsyncSemaphore internals beyond `withPermit`, and `JobPauseCoordinator`'s SIGSTOP timing, were not traced.
- CheckMediaJob beyond its gate use (F3 and the resume-during-close note) was not reviewed. It belongs to the separate Check Media audit row.
- `PromoteToArchiveJob+Steps.swift` was not read. I relied on `run()` returning to `runHoldingGates`' tail for release, and the
  Steps functions are called from `run()`.
- Whether anything re-renders a Check Media row while it is queued (F3 is NEEDS-MAC for this reason).

## Blockers & environment

- Per the brief I did not commit or push: this session was told the report file is its only output. That overrides the
  README's "commit on `cloud/<id>`" rule, so the Manager needs to pick the file up from this session's working tree, or
  rerun with push allowed.
- I did not install lizard (as the brief says). I used `ci/baselines/complexity_debt.json` and `origin/metrics` (fetch worked).
- The history was not shallow; `df616324` and `cc96861f` resolved without `--deepen`.
- The wall clock is the container clock (start to finish). It looks low against the amount of tool work done, so treat it as approximate.
