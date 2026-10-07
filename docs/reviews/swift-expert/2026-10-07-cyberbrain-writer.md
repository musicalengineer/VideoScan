# swift-expert review — 2026-10-07: CyberBrainWriter split (codex, 7b919780)

Behaviour: qa OK (codex's 6 characterization tests pass on the old code; 57 CyberBrain tests green;
save order, root lock and damaged-file handling unchanged). This review grades design only.

**Verdict: Acceptable.** A clean layer split for captions / pronunciations / persistence, but the
testimony half is a reshuffle, and the one duplication the split should have removed (two copies of
the subject-resolution ladder) survived it.

| # | Grade | Evidence |
|---|---|---|
| 1 Naming | B+ | Verb names as asked (`appendTestimonySource`, `resolveCaptionSubjects`). `appendTestimonyItem` (+Testimony:165) returns the person *before* the append. |
| 2 Types | B- | `TestimonySubject` is a good value type. `appendTestimonySource` returns a bare `(id:, itemPrefix:, confidence:)` tuple, re-spelled as a parameter type at +Testimony:147. |
| 3 Decomposition | C+ | `appending(_:to:)` went from one readable top-to-bottom function to five privates that only work in fixed order, threading six values. `resolveTestimonySubject` (+Testimony:69) is still a near-copy of `resolveSubject` (+Subjects:11). +Subjects is a grab bag. |
| 4 Concurrency | A- | Unchanged and correct; `withRootLock` preserved. |
| 6 Errors | B | Priority preserved. Pre-existing: `citation` doc says missing citation is `emptySubject`; code throws `ioFailure` (+Sources:76). |
| 7 Testability | A- | Six characterization tests with real contracts. |
| 8 Docs | B+ | Incident comments moved intact. |

**Next changes, priority order:**
1. One resolution ladder: give `resolveSubject` a `LinkPolicy { immediately, deferred }` and delete
   `resolveTestimonySubject` (C++: two hand-synced copies of one `switch` in two translation units).
2. Replace the origin tuple with `struct OriginStamp { sourceID; itemPrefix; confidence }`.
3. Keep each pure operation next to its durable wrapper (`appending` ↔ `record`); keep only
   `save` / `prepareRoot` / `backup` in +Persistence.

Swift note for Rick: `private` is file-scoped, so splitting into extension files forced four helpers
from private to internal, growing the module's API surface. (In C++, a member defined in another .cpp
stays private; in Swift it doesn't.)

Still open, separate: plain `fsync` instead of F_FULLFSYNC (CC N1009-D-F2).
