# swift-expert review — 2026-10-07: ArchivistGraphExecutor split (codex, 5925ef01)

**Verdict: Good**, a genuine improvement: a 180-line switch became a 15-line dispatch over four named
routes via an immutable `ResolvedSubject`; `resolveUnselected` reads top to bottom (profiles → given name
→ exact → loose → fuzzy). Structs, not tuples: applied. Paired operations: mostly applied.

**Not applied: no private→internal widening.** Ten symbols went private→internal (`Resolution`,
`ProfileRoute`, `executeResolved`, `fromPolicy`, `biographyEvidence`, `lifeDateEvidence`,
`declineUnexpectedRelation`, `identityBridge`, `normalize`, `nameOrder`) plus two new internal entry points,
none used outside the executor's own files. The same miss as the CyberBrainWriter split.

Next changes:
1. Close the access surface with a TYPE, not a file: `enum ArchivistProfileBridge { static func resolve(…); private static … }`
   (Swift `private` is file-scoped, like a C++ anonymous namespace: split the .cpp and the shared parts land in the header).
2. Merge the verbatim twins `lifePlace` / `lifeDate` (+Operations:135-204) into one `lifeFact(_:place:)`.
3. Refile by job: `fromPolicy` beside `decline` in the core file; `peopleTabKin` into `+KinshipOverlay.swift`.
Minor: document `resolveProfileName`'s nil-means-fall-through contract; a stale "(nil only for legacy
callers)" comment at +Resolution:136.
