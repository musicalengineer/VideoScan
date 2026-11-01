# Codex review — Swift 6 stage 8 flip

- Range: `b6184158b..2f7468640`
- Credits spent: unavailable (not exposed)
- Tokens: 155244
- Finding count: 0
- Verdict: merge — No scoped regression found in `b6184158b..2f7468640`; the exact-HEAD sensor run must still finish GREEN.
- Run: 2026-10-25T20:32:08Z (cycle #139, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (not exposed) | Finding count: 0
Verdict: merge — No scoped regression found in `b6184158b..2f7468640`; the exact-HEAD sensor run must still finish GREEN.

Five invariants checked:

1. **Writer isolation:** the store’s entire read/write implementation is byte-identical; writer entry points retain their `flock` protection. `Sendable` introduces no shared mutable configuration. (`docs/DESIGN.md` §§7–8.)
2. **Closure binding:** no changed binding found in scoped code or relevant callers. Multiple callbacks are explicitly labeled or retain their required parameter binding under [SE-0286](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0286-forward-scan-trailing-closures.md). (§§6–7.)
3. **Log ordering:** promote/refuse/rollback logs and FamilySearch merge logs retain their positions relative to pointer writes and file moves. (§6.)
4. **Weak references:** both callbacks still resolve the weak reference and check their generation on `MainActor`; neither adds a strong model capture. (§7.)
5. **FileManager:** all eight coordinator construction sites at the base revision omit `fileManager:`. The loader’s sole explicit injection came from that coordinator’s default instance. (§8.)

File verdicts:

- `FamilyGraphCompiledStore.swift` — read, no findings.
- `FamilyGraphFileLoader.swift` — read, no findings.
- `FamilySearchPullCoordinator.swift` — read, no findings.
- `FamilyTreeLiveModel.swift` — read, no findings.
- `FamilyTreeLaunchBundle.swift` — read, no findings.
- `RelocateSheet.swift` — read, no findings.
- `DeleteDuplicatesVolumePicker.swift` — read, no findings.
- `project.pbxproj` — read, no findings.

Inspected `WeakRef.swift` as the dependency necessary to verify invariant 4. No broader implementation review.

Runtime tests executed here: **0**, because the sandbox is read-only. Reviewed relevant test code and ran read-only source comparisons; relied on supplied build/test results. No files changed.

## Brief

# Codex review brief — Swift 6 stage 8: the language-mode flip (data-risk files only)

**Workflow in one sentence (the user's words):** "flip the app target to Swift 6 language mode; fix what the compiler finds; change no behaviour."

**Range:** `b6184158b..2f7468640` on branch `swift6/stage8-flip` · **Worktree:** `/Users/rickb/dev/VideoScan-wt/swift6-flip`

**In scope (read these and their direct callers; nothing else):**
- `VideoScan/VideoScanCore/Sources/VideoScanCore/FamilyGraphCompiledStore.swift` — the type is now `Sendable`: `log`/`verify` are `@Sendable`, `fileManager` is a computed `.default` (was a stored `var` nobody injected), `Pointer`/`Source`/`LogicalSource`/`Manifest` are `Sendable`. The writers (`ingest`, `ingestLocked`, `adopt`, `rollback`, `repoint`, `prune`, `withLock`) are textually unchanged.
- `VideoScan/VideoScan/FamilyTree/FamilyGraphFileLoader.swift` — `Sendable`; `progress`/`log` are `@Sendable`; `fileManager` computed.
- `VideoScan/VideoScan/FamilyTree/FamilySearchPullCoordinator.swift` — the never-injected `fileManager:` init parameter is gone; `fileManager` is a computed `.default`; the detached merge task reads `FileManager.default` itself instead of capturing the coordinator's instance; `currentTreeLoader` no longer passes a FileManager.
- `VideoScan/VideoScan/FamilyTree/FamilyTreeLiveModel.swift` — `loadFromDisk` and `recompile`: the two `Task.detached { [weak self] … }` closures now capture a let-bound `WeakRef(self)`; the progress closure is built on the main actor before the detached task and handed in by copy. Nothing else in the file changed.
- `VideoScan/VideoScan/FamilyTree/FamilyTreeLaunchBundle.swift` — `precondition` on a duplicate anchor id inside the lock (restores the fail-fast of the `Dictionary(uniqueKeysWithValues:)` it replaced in slice A).
- `VideoScan/VideoScan/MediaOps/RelocateSheet.swift` — `derivedDestination(chosen:sourcePath:)` and `normalizeSourcePath` are `nonisolated static` (pure string functions; the only change).
- `VideoScan/VideoScan/MediaOps/DeleteDuplicatesVolumePicker.swift` — `preselected(in:path:)` and `others(in:path:)` are `nonisolated static` (pure; the only change).
- `VideoScan/VideoScan.xcodeproj/project.pbxproj` — `SWIFT_VERSION 5.0 → 6.0` (6 occurrences); the two `SWIFT_STRICT_CONCURRENCY = complete` lines removed (implicit in Swift 6 mode).

**Invariants to attack** (one line each; cite `docs/DESIGN.md` §):
1. No write reaches the catalog, the compiled family-tree store or the archive from a second isolation context: every store writer still runs under `withLock` (flock) on the same code path, and `Sendable` on the store did not let a copy be mutated concurrently in a way the flock does not cover.
2. Trailing-closure rebinding changed no call's meaning: for every call site of a function with two or more closure parameters in these files, the closure binds to the same parameter it did in Swift 5 mode (SE-0286 — Swift 6 binds a trailing closure to the FIRST closure-typed parameter).
3. OUTCOME/START log ordering is unchanged: the `[family-tree]` promote/refuse/rollback lines and the FamilySearch merge lines are emitted in the same order relative to the pointer write and the file moves as before.
4. The `WeakRef` change in `FamilyTreeLiveModel` keeps the generation guards: a caption for a superseded load/recompile is still dropped (`loadGeneration`/`captionGeneration` checks run on the main actor, as before), and the model is not retained by the detached task past its lifetime any more than it was.
5. The `fileManager` removal in `FamilySearchPullCoordinator` changed nothing observable: no caller ever passed a non-default `FileManager` (grep the tests), so staging, copy and remove go through the same `.default` instance they did.

**Evidence already run:** clean Debug `build-for-testing` in Swift 6 mode: 0 errors, 1 warning (the documented mlx deprecation); `warning_ratchet.py check` GREEN. Core full suite 1,650 Swift Testing / 232 suites + 223 XCTest, 0 failures. App related suites 139 (every suite in a touched file + every suite named for a touched type): 871 Swift Testing in 135 suites + XCTest 59+9, 0 failures except one timing-probe bench assertion under investigation (HallieQueryBench `mainActorResidentWork`, see the commit message). Sensor lane: `sensor lane GREEN (570 tests)` on the pre-amend tree; re-run on HEAD in progress.

**Known and accepted (do not report):** `nonisolated(unsafe)` on three immutable `let`s in tests only (StressTests `shared`, HallieQueryBench `records`), each with the invariant comment; the mlx-swift deprecation (no replacement API); the `Dictionary(uniqueKeysWithValues:)` → lock + `precondition` is intentional.

**Output contract:**
```
Credits spent: <amount> | Finding count: <N>
Verdict: merge | fix | block — <one sentence>
```
Then findings ranked by data-loss risk, each with `file:line`, a reproduction, and a RED test where possible. For every in-scope file with nothing to report write "read, no findings." Do not explore outside the files above unless a finding requires it, and say so.
