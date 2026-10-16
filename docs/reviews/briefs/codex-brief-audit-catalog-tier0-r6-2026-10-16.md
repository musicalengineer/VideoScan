# Codex brief: Audit Catalog tier 0 — round 6 (the r5 delta only)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~400 words. This reviews ONLY the round-5 delta. If no P1 remains, say "merge": Rick then runs the first real audit (it stamps and lists; it marks nothing until a second run).

**One sentence:** check that every catalog row on a connected drive still points at its file, and mark the ones that are gone as Missing.

**Rounds 1–5:** `docs/reviews/codex/codex-review-audit-catalog-tier-0-{freshness,r2,r3,r4,r5}-2026-10-16.md`, each with a Closure.

**Range:** the one commit on `main` after `3c23af83a` whose subject starts `fix(audit): codex r5 closed` (`git log --oneline 3c23af83a..main -- VideoScan/VideoScan/MediaOps/CatalogAuditPlan.swift`). Paths under `VideoScan/VideoScan/`.
- `MediaOps/DeleteDuplicatesDrives.swift` — `deviceIdentification(mountFrom:isLocal:device:) -> (key: String?, identified: Bool)`; `physicalDeviceKey` now delegates to it.
- `MediaOps/CatalogAuditPlan.swift` — `CatalogAuditMountIdentity.deviceIdentified` (default true; false only for a local `.unknown`), `of(fd:)` fills it, `seenOn(at:)` returns nil when not identified.
- `VideoScan/VideoScanCore/Sources/VideoScanCore/VideoRecord.swift` — `fullPath.didSet` clears `auditSeenOn` on ANY path change.
- Tests: `VideoScan/VideoScanTests/CatalogAuditRound2Tests.swift` (`unidentifiedLocalDriveWritesNoStamp`, `aPathChangeClearsTheStamp`), `CatalogAuditJobTests.swift` sensor `expectProofAtTheMark`.

**Attack:**
1. Is there still a way a LOCAL drive gets a key-less stamp? (`isLocal` true, kind `.diskImage` is intended: a DMG is "the volume"; kind `.network` cannot be local; anything else?) Is `deviceIdentified`'s default of `true` reachable from any constructor other than `of(fd:)` in production?
2. Does the proof side need the same guard — a stamp WITH a key against a handle whose drive is `.unknown` → already "cannot be identified, a clone? not marked" (r4); a stamp WITHOUT a key (share/DMG) against an `.unknown` local handle → proves by UUID: acceptable or a hole?
3. `fullPath.didSet` on any change: any writer that assigns `fullPath` to its CURRENT value as a no-op (clears nothing — equality guard present) or that rebuilds a record via `init(from:)` with a stale stamp (decoder runs no didSet — stated acceptable in r5).

**Do only this:** findings against 1–3 (P1 first), each with file:line and a one-line failure scenario; at most one P2/P3 one-liner. Everything else is out of scope and closed.

**Do not explore outside the files listed above and their tests.**
