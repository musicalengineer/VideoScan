# Reading guide: one module to copy, one to fix (2026-10-18)

swift-expert (run on Opus; Fable was out of credits), main @ 9c9738c93. Read-only review for Rick's paired reading.
Spot-checked by the Manager: 134 `extension VideoScanModel` files, 90 `@Published` in VideoScanModel.swift, `CatalogOpenOutcome` at Store/CatalogRepository.swift:43, `fam[0]` fallback at PrunePlan.swift:1002.

CORE = `VideoScan/VideoScanCore/Sources/VideoScanCore`, APP = `VideoScan/VideoScan`.

## 1. Exemplar — `Core/Commit` + the Store seam (grade A, earned; "Good, near Exemplary")

1. `CORE/Store/CatalogRepository.swift:43-87`, then `:333-390`.
   - Outcomes are enums (`CatalogWriteOutcome`, `CatalogOpenOutcome`). Think `std::variant` that callers must `switch` on with no `default:`, so adding a case makes the compiler flag every caller.
   - Only "store not open" is thrown (`CatalogRepositoryError`); everything else is returned as a value. That is the right split between exceptions and return codes.
   - `CatalogRepository` is a protocol with async requirements: an abstract base whose virtuals are coroutines. It has two real implementations (GRDB and JSON), so the seam is genuine.
   - The `@Sendable` body closure is checked by the compiler for data races.
2. `CORE/Commit/CatalogCommit.swift:47-196`.
   - The case-less `enum CatalogCommit` is a namespace.
   - `Item` and `Plan` are structs: value semantics with copy-on-write.
   - `Landing` (`:98-139`) puts its derived questions on the enum itself, as exhaustive switches. That's `std::visit` done well.
   - `run` never throws (`:166`); every ending is an `Outcome`.
3. `CORE/Commit/CatalogCommitBody.swift:64-140`.
   - `run()` is one flat loop.
   - `commit(_:)` switches on `digestState` (`:112`) and names all three states.
   - Each record gets its own savepoint, so a bad row rolls back only itself: RAII scoping applied to a transaction.
4. (optional) `CORE/Commit/CatalogChangeDetector.swift:49-76`.
   - The header comment records the measurements behind the design.
   - The `try?` at `:75` is deliberate and documented.
   - `nonisolated(unsafe)` at `:59` is a justified "trust me" for disjoint writes.

Weaknesses even here:
- Ticket codes in comments ("B2.1 gap 3", "codex P1-6") are history, not explanation.
- `CatalogCommitLedger` (`CatalogCommit.swift:200`) is a class marked `@unchecked Sendable` with an `NSLock` inside. `Synchronization.Mutex<State>` (macOS 15) would let the compiler check it instead.

## 2. Counter-example — `Model/VideoScanModel.swift` ("Needs redesign")

1. `APP/Model/VideoScanModel.swift:10-42`.
   - One `@MainActor ObservableObject` (main-thread-only) with about 90 `@Published` properties, extended by 134 files. In C++ terms: one partial class across 134 translation units, all sharing one mutable member set.
   - The `records` `didSet` (`:18-41`) fans out into about seven subsystems. Every feature adds a line, and the type can't be understood one piece at a time.
2. `APP/Model/VideoScanModel.swift:55-129`, `:131-132`, `:260-264`, `:509-513`.
   - **Flag soup:** `isScanning`, `isCombining`, `isCorrelating`, … are separate Bools, so illegal combinations are possible.
   - **Stringly-typed status:** `correlateStatus` and `duplicateStatus` are plain Strings.
   - **Unstructured debounce:** a fire-and-forget `Task` plus `try? await Task.sleep`, controlled by a hand-kept `…Scheduled` Bool.
   - **Test hooks in production:** `…ForTesting` closures on the shipping type.
3. `CORE/PrunePlan.swift:999-1152` (`plan(family:)`, CCN 52).
   - The problem is the result type. `make(...)` (`:1078`) takes 25 arguments to build `Family`, a struct of flags describing three exclusive outcomes. It should be a variant.
   - Stringly-typed checks: `contentKeyKind != "h"` (`:1076`) and the `derivationKind` string switch (`:553`).
   - `fam[0]` (`:1002`) traps on an empty family.
   - `(CopyRow.Role, KeepReason?, Bool)` (`:1184`) is an anonymous tuple.

What the A-grade version would look like:
- **Split by feature:** separate `@Observable @MainActor` stores (CatalogStore, RelocateQueue, DuplicateJobs, PreviewService), injected through `@Environment`.
- **One state enum instead of flags:** `enum Activity { case idle, scanning(Progress), correlating(Progress) }`.
- **Explicit change notifications:** an `AsyncStream` of catalog changes instead of the `didSet` fan-out. Debouncing done by one owned, cancellable `Task`.
- **Typed results for PrunePlan:** `enum Verdict { case blocked(KeepReason, advice:), barNotMet(shortfall:, hintedKeeper:), covered(keeper:, trash:) }`, plus `ContentKeyKind: Character` and `DerivationKind: String` enums.

## Where the reviewer disagrees with the metric grades
- **PrunePlan ≈ B−, not C/D.** It is pure, deterministic and testable over value types. Splitting the function just to lower CCN would be cosmetic; the typed `Verdict` is the real fix.
- **Steward and Events are B at most.** Their `VideoScanModel+Steward.swift` / `+Events.swift` extend the god object. Steward also uses `Task.detached` plus an `@unchecked Sendable` lock-handoff class (`APP/Steward/VideoScanModel+Steward.swift:59-75`). Grading by folder misses code that lives in another type.
- **Commit's A is earned.**

## What to look for in any Swift file
1. Who owns this state, and on which thread? Is it a struct, or a class with a reason to be one? Does each enum case carry its own data, instead of parallel flags?
2. Does every `try?`, `@unchecked Sendable`, `Task {}` or `nonisolated(unsafe)` have a comment justifying it? Could the logic be tested without the UI or the disk?
