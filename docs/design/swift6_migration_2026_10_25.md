# Swift 6 language mode: the migration plan

Rick's ruling, 2026-10-25: *"we need to be using the latest swift 6 … there is no reason to allow for older compatibility issues, as this is not yet a shipping product … in stages, within a week or sooner."* This document is the plan any session (Opus, Fable, a worker) carries out. It is retired to `docs/archive/` when stage 8 lands.

## 1. What is true today (measured 2026-10-25, main `4a6607ed3`)

- Toolchain: Xcode 27.0, Swift 6.4. **Language mode: Swift 5** in both the app target (`SWIFT_VERSION = 5.0`, unchanged since 2026-04-04) and VideoScanCore (`swiftLanguageModes: [.v5]`). Nobody ever switched it; the "Swift 6" in `CLAUDE.md` was the toolchain.
- Strict concurrency checking has been **on since 2026-09-22** (`ab77d49b8`). In Swift 5 mode its findings are warnings. A clean Debug build of the app carried **489 distinct warnings in 325 files**; ~390 of them are concurrency findings that Swift 6 mode reports as errors. At that volume a new warning is invisible, which is the actual failure: the analysis ran for a month and nobody could act on it.
- Core had 3 warning sites and 1 test that blocked Swift 6 mode (a semaphore wait in an async test). Stage 1 fixed those.

## 2. What Swift 6 mode buys, and what it does not

Swift 6 mode does not add analysis; it gives the existing analysis **teeth**. `Sendable` is the type-level mark "safe to hand to another thread"; an actor is a class whose state is reachable only from its own serialized context — a private mutex the compiler knows about. The checker follows every closure capture, every `Task {}` boundary, every value returned from an actor, and refuses any path where mutable non-Sendable state could be touched from two contexts at once. That is a compile-time proof of absence of data races on all tracked state — clang's `-Wthread-safety` as a type system, inferred through captures rather than annotated locks.

VideoScan is the shape where races are likely and silent: one committer on the catalog, MFO jobs on background queues, per-drive hash readers, Archive Angel reassessing while the UI reads, SwiftUI on the main actor. A race there writes a wrong row, not a crash (rules 1 and 2).

Holes, stated plainly:
- `@unchecked Sendable` and `nonisolated(unsafe)` are opt-outs from the proof. Each one is a hole. **Policy (§5): every opt-out carries a comment that says why the access is actually safe, and the nightly counts them.** Silencing a warning with one of these instead of fixing it is the Swift equivalent of a `const_cast` to make a warning go away.
- Nothing is proven across C boundaries (ffmpeg/ffprobe are separate processes, fine; the Metal/ArcFace pointer code is unchecked — sanitizers cover it, §7).
- A migration edit can change behaviour: isolating a property to the main actor adds an `await`, which changes ordering. Every slice runs its related suites; a behaviour change ships a red/green test (rule 7).

## 3. Measurement — the morning number

`scripts/warning_ratchet.py` (stage 0) owns the numbers:

- **Baseline:** `scripts/warnings_baseline.tsv`, warning counts per **(file, category)** from **clean** builds in the sensor lane's own configuration — Debug `xcodebuild build-for-testing` with the lane's flags, plus `swift build --build-tests -vv` for Core (the `-vv` prints one `Compile X.swift` line per file: the compile evidence `update` demands before it lets a file's count fall to zero; Core's sources are also evidenced by xcodebuild, which builds the package). Same configuration day and night, so Debug-only and toolchain-specific warnings are in the baseline, not a surprise. `# start_total` is written once (the denominator) and never moves.
- **Ratchet:** `check` compares a build log with the baseline **per (file, category)** (an incremental build recompiles only changed files, so totals mean nothing, but a file that emits a warning was compiled and its counts are exact; per category, so a deprecation fix can never pay for a new concurrency finding). Any (file, category) above its baseline is RED; a missing baseline is one red line, not one per file. The sensor lane calls it on its own two logs, so every merge is checked with no extra step.
- **Progress:** `progress` prints one line: `Swift 6 progress: N% — R of S warnings remain · Core: Swift 6 · App: Swift 5 (flips at 0)`. N = cleared ÷ start_total; 100 % needs the app target in Swift 6 mode and a total of 0 (99 % until the flip). The session-start hook prints this line, so Rick sees it every morning. **Who lowers the baseline (decision 2026-10-25): the merging session**, from each slice's clean build logs (`update --clean`), so the file in `main` always matches what was merged. The nightly **verifies and reports**: its clean build runs `check` (a rise overnight is RED), prints `progress --markdown` and `categories` into its report, and when its clean counts are below the committed baseline it says *"baseline can be lowered: B → N"* — it never writes the file and never commits to `main`.
- `categories <log>` breaks a log down by fix category (the table in §6), for picking the next slice.

A per-file "Swift 6 warnings" column on the metrics board is the same TSV; Rick's idea (10/25) is in `docs/BACKLOG.md` for stage 2.

## 4. Stages

| # | Scope | Exit criterion | Status |
|---|---|---|---|
| 0 | `warning_ratchet.py`; baseline committed; sensor lane runs `check`; session-start prints `progress`; this doc; `DECISIONS`/`STATUS`/`CLAUDE.md` corrected | sensors GREEN with the ratchet in the lane | **done 10/25** |
| 1 | VideoScanCore in Swift 6 mode (`swiftLanguageModes: [.v6]`) | `swift test` 1,872/0 in v6 | **done 10/25** |
| 2 | Nightly analysis lane (§7) on the fleet, report mode: clean build + `check` + progress line + "baseline can be lowered" each night (the merging session lowers it) | one green nightly with the lane's numbers in the report | built 10/25 (`scripts/nightly_analysis_lane.sh`); first fleet night pending |
| 3 | Non-concurrency warnings: deprecated API (`Text +`, `String(cString:)` on arrays), `??` on non-optionals, redundant `nonisolated(unsafe)`, `[weak x]` vs implicit strong capture | category count 0 | |
| 4 | Globals and statics "not concurrency-safe" (~148) | category count 0 | |
| 5 | Main-actor state referenced from nonisolated code (~40) | category count 0 | |
| 6 | Closure captures, `sending`, region isolation (~120). **Codex pass per slice that touches data-risk code** (`Archive/`, delete/prune/relocate in `MediaOps/`, FamilyTree writers, `ArchiveAngel/Promote/`, volume retire) | category count 0 | |
| 7 | Missing `Sendable` conformances; non-Sendable results leaving actors (~30) | category count 0 | |
| 8 | App target `SWIFT_VERSION = 6`; delete `SWIFT_STRICT_CONCURRENCY = complete` (implicit); ratchet floor becomes "any warning is red" | clean build 0 errors 0 warnings; full suite green; Codex pass on the flip diff | |

Stages 3–7 run as worker slices in worktrees, one category per branch, 20–60 files per branch, fleet/night shift first and Rick's machine only for Debug incremental builds. Stages can interleave by module (a worker may take "Hallie/ stages 4+5") when that keeps a branch file-disjoint from another. Merge order does not matter; the ratchet keeps every merge monotone.

## 5. Rules for every slice

1. **Fix, don't silence.** The correct fix per category is in §6. `nonisolated(unsafe)` / `@unchecked Sendable` only where the access is provably safe for a reason the compiler cannot see (disjoint index ranges, a type that is immutable after init but holds a class, a thread-safe Apple type the SDK has not yet marked), and only with a one-line `// Swift 6:` comment saying why. The nightly's count of these must not rise across a slice without that justification in the diff.
2. **No behaviour change without a red/green test.** Changing a type to an actor, hopping to `@MainActor`, or adding an `await` on a path that writes to the catalog is a behaviour change.
3. **One category per branch; related suites + `scripts/run_sensors.sh` green; the ratchet green.** Commit message quotes the category count before → after.
4. **Data-risk code (rule 10) gets a scoped Codex brief** (`docs/reviews/BRIEF_TEMPLATE.md`): SHA range, the files, the invariant ("no write reaches the catalog from a second isolation context"; "the trash proof still runs before unlink"), test evidence, verdict contract.
5. **Never on Rick's checkout.** Worktree + own `-derivedDataPath`. The checkout stays on `main` and clean.

## 6. The correct fix by category (what the warning means, what to do)

| Warning | Meaning (C++ terms) | Correct fix | Not acceptable |
|---|---|---|---|
| `static property 'x' is not concurrency-safe because non-Sendable type` | a global without a mutex, as far as the compiler can tell | make the value's type `Sendable` (most are immutable tables: add `Sendable` to the struct/enum, use `let`); key-path tables: `KeyPath<…> & Sendable`; a per-type `UserDefaults` handle: `nonisolated(unsafe)` with the comment "UserDefaults is thread-safe (Apple docs); not yet marked Sendable in this SDK" | blanket `nonisolated(unsafe)` on a mutable `static var` — that is the race the checker found |
| `main actor-isolated static property … referenced from a nonisolated context` | reading UI-thread state from a worker | if the value is immutable, move it off the actor (`nonisolated static let`); if it is UI state, the caller belongs on the main actor (`@MainActor func`/`await MainActor.run`) | `MainActor.assumeIsolated` without a reason |
| `capture of 'x' with non-Sendable type … in a @Sendable closure` / `sending 'x' risks causing data races` | a non-thread-safe object handed to another thread | make the captured type `Sendable` (value types: often free; classes: make them `final` with `let` members, or an `actor`); or copy out the Sendable fields before the `Task {}`; or keep the work on the owning actor | `@unchecked Sendable` on a class with `var`s |
| `reference to captured var in concurrently-executing code` / `mutation of captured var` | a local `var` written from a concurrent closure | collect results per task and merge after (`withTaskGroup` returning values); for disjoint index writes use a buffer with the documented `nonisolated(unsafe)` (see `FamilyTreeNameSearch.swift`) | — |
| `type 'X' does not conform to the 'Sendable' protocol` | the compiler needs a conformance it cannot infer (public type, or a class) | add `Sendable` where the type is a value with Sendable members; for a class, `final` + `let` members → `Sendable`; a class with mutable state → `actor` or `@MainActor` | `@unchecked Sendable` without an invariant comment |
| `non-Sendable result returned from actor-isolated method` | an actor handed out its internal object | return a Sendable snapshot (struct), not the live object | — |
| `instance method 'wait' is unavailable from asynchronous contexts` | blocking a cooperative thread | an `AsyncStream`/continuation for the signal; keep semaphores inside synchronous bodies | — |
| `'weak' ownership of capture differs from implicitly-captured strong reference` | `[weak self]` on the outer closure, `self` strong in an inner one — the weak is a lie | capture consistently (`[weak self]` on the inner closure too, with `guard let self`) | — |
| deprecated API | — | the replacement the message names | `@available` silencing |

### 6a. Swift 6 mode changes that are not warnings today (found in Core, stage 1)

These compile silently in Swift 5 mode and fail only when the mode flips, so the ratchet cannot see them; the stage 8 flip build is where they surface. Known so far:

- **Trailing closures bind to the first closure-typed parameter** (SE-0286). Swift 5 skipped a defaulted `() -> Bool` when the trailing closure took an argument; Swift 6 does not. Symptom: `contextual closure type '() -> Bool' expects 0 arguments, but 1 was used`, followed by a cascade of "cannot infer" errors. Fix the API, not the callers: the intended trailing closure must be the first closure-typed parameter (`TreeWalker.walk` moved `emit:` before `isCancelled:`). Grep for functions with two closure parameters where the first is defaulted.
- **A file-level `let` of closure type must be `@Sendable`** (`private let f: @Sendable (A) -> B = …`); a global closure is a global.
- **A `var` captured by a `@Sendable` closure, even under a lock**, is an error; the lock has to own the state (`OSAllocatedUnfairLock<T>` on macOS 13+, `Mutex<T>` on 15+).
- **`DispatchSemaphore.wait()` in an `async` function** is unavailable; signal with an `AsyncStream`/continuation instead.

## 7. Stage 2 — the nightly analysis lane (the Coverity analogue)

Runs on the fleet in the away window, never on Rick's machine; each item prints a number (rule 9) and the lane's report lists them. Language mode is **not** nightly-only: it changes what code means, so day and night build the same mode. **The lane verifies and reports; it never commits to `main` and never writes `scripts/warnings_baseline.tsv`** (decision 2026-10-25; the merging session lowers the baseline, §3). The lane adds what is too slow or too noisy for rapid dev:

| Check | Catches | Mode |
|---|---|---|
| clean Debug `build-for-testing` (the sensor lane's exact flags) + clean `swift build --build-tests -vv`, then `warning_ratchet.py check`; `progress --markdown` and `categories` into the report; "baseline can be lowered: B → N" when the clean counts are below the committed baseline | a regression overnight (RED); the morning number | report; the file is written by the merging session (`update --clean`), never here |
| escape-hatch census (`nonisolated(unsafe)`, `@unchecked Sendable`, `assumeIsolated`, `withLockUnchecked`/`uncheckedState`, `Unsafe*Pointer`, `unsafeBitCast`, `try!`, `as!`, force-unwrap via swiftlint) per target with per-file deltas against the previous night (`scripts/escape_hatch_census.py`) | holes in the proof | report now; ratchet the opt-out kinds once quiet for a week (TODO in the script) |
| Thread Sanitizer test pass (Core + app, Release, `weekly_sanitizer.py --configuration Release --target all`) | races through the holes, at runtime | red on a finding; one kind per night (`--sanitizer auto`, rota weekday map) |
| Address + UB Sanitizer test pass (share a build; cannot share one with TSan) | memory errors in pointer code (ArcFace, Metal, frame buffers) | red on a finding; `--subset catalog` = Core + the catalog/MFO/Archive app suites when the window is short |
| `-strict-memory-safety` build (Swift 6.2+, probed; own DerivedData, `OTHER_SWIFT_FLAGS`) | every unsafe construct, counted | report, then ratchet; 🟡 with the reason on a toolchain that lacks it |
| Periphery (`--skip-build` on the clean build's index store, 21 s); `swiftlint analyze` (unused_import, unused_declaration) is plumbed but opt-in — measured 10/25: each file's SourceKit index request re-typechecks the whole ~1,400-file app module, so one 70-file folder had not finished after 540 s (O(files²) on one big module) | unused imports/declarations, dead code | report, then ratchet; third-party excluded |

Implementation: `scripts/nightly_analysis_lane.sh` (processes, paths, watchdogs) + `scripts/analysis_lane.py` (one line with a number per stage, the verdict, `latest.json`, the markdown report, the morning `alert`); installed by `scripts/install_analysis_lane.sh` at the rota's `analysis` slot (`scripts/nightly_rota.json`, M4 04:30); harness `scripts/test_nightly_analysis_lane.sh`. Results stay local to the Mac that ran it (`~/Library/Logs/VideoScan/swift6-analysis/`, like the sanitizer and Hallie-voice lanes) and reach the morning through `.claude/scripts/session_start.sh` and `scripts/morning_metrics.sh`.

Not in the lane: Coverity itself (commercial, vendor-hosted; Rick prefers self-hosted, and Swift 6 mode + sanitizers cover what it would add here).

## 8. Worker brief (copy, fill the brackets)

```
Task: Swift 6 stage [N] — [category] in [module globs]. Plan: docs/design/swift6_migration_2026_10_25.md §5–§6.
Worktree: git -C ~/dev/VideoScan worktree add -b swift6/[stage]-[module] ~/dev/VideoScan-wt/swift6-[stage]-[module] main
DerivedData: your own path. Never touch ~/dev/VideoScan.
Use unique log/DerivedData names — workers share the scratch dir.
Before: python3 scripts/warning_ratchet.py categories <clean build log>  → quote the category count.
Do: fix every "[category]" warning in the files listed; the correct fix is §6; opt-outs need the `// Swift 6:` comment.
Tests: related suites for every touched type; a red/green test for any behaviour change; scripts/run_sensors.sh --derived-data <dd> GREEN (it runs the ratchet).
Codex: if a touched file is in the rule-10 map, write the brief (docs/reviews/BRIEF_TEMPLATE.md) and run tools/codex_review.py before reporting.
Report: category count before → after, test counts, the escape-hatch delta, the branch name. Do not merge; the manager merges
(and lowers scripts/warnings_baseline.tsv from your clean build logs with `warning_ratchet.py update --clean` — the nightly never does).
```

## 9. Risks and what retires them

- **Suppression instead of fixes** → §5 rule 1 + the nightly escape-hatch count; the reviewer agent reads every `nonisolated(unsafe)` in a slice diff.
- **Behaviour drift from isolation changes** → related suites per slice, red/green on writers, the gauntlet nightly, Codex on data-risk slices.
- **Churn during "stability before the Ultra"** → stages 0–2 are low-churn; 3–7 are night-shift slices with the ratchet holding the floor; the checkout is never touched.
- **A slice that cannot reach 0 for its category** → it stops at a documented list of justified opt-outs, each with its comment; the count is the nightly's.
