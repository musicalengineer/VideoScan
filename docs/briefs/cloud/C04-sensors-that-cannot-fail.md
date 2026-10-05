# C04 — Tests that cannot fail: the data-risk sensors

Inherits `docs/briefs/cloud/README.md`. Report: `docs/reviews/cloud/C04-sensors-that-cannot-fail.md`.

**Kind:** deep pass on the tests themselves. A sensor that can never go red
is worse than none: it makes everyone believe a guard exists.

## Scope (`VideoScan/VideoScanTests/`)
`DeleteDuplicates*Tests.swift`, `ReadOnlyVolume*Tests.swift`, `*Promote*Tests.swift`,
`*Fixity*Tests.swift`, `*Ledger*Tests.swift`, `*Prune*Tests.swift`,
`*Relocate*Tests.swift`, `*Trash*Tests.swift`, plus the source-sensor helper
`SourceTree` (`VideoScan/VideoScanTests/SourceTree.swift`). About 61 files: do
item 3 first, then items 1–2 on the files item 3 led you to. Follow a test into the production symbol it pins
only far enough to judge whether the assertion would fail if that guard were removed.

## Find
1. **Vacuous asserts:** `#expect` over an empty collection, a loop that runs zero
   times, `XCTAssert` on a value the test itself just set, `try?` that turns a
   throw into a pass, an early `return` under a condition that's always true in CI
   (`isCI`, a missing fixture, a missing tool) with no `XCTSkip`/`.disabled` so it
   reports as PASS.
2. **Source sensors that match too loosely:** a `contains("…")` on source text
   that would still match after the guard was deleted (the string appears in a
   comment, or in another function). A sensor that looks a file up by a name that no
   longer exists must fail, not pass. Check what `SourceTree.appSource(named:)` does then.
3. **Mutation by reading:** for the ~15 most important guards (two-drive survivor rule,
   Read-only refusal, archive-copy hold, fail-closed on unreadable evidence,
   never-clobber publish), name the test that would go red if the guard line were
   deleted. A guard with no such test is a finding (P2), with the pinning test to add.

Out of scope: test style, speed, naming.
