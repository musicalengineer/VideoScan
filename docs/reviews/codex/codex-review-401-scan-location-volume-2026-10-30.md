# Codex review — 401 scan location volume

- Range: `1f2e1b48..eeb50f9d`
- Credits spent: unavailable
- Tokens: 53079
- Finding count: 1
- Verdict: fix — make overlap ownership consistent between the Delete count and removal planner.
- Run: 2026-10-30T18:55:48Z (cycle #184, tools/codex_review.py)

## Codex answer

**P1 — Delete count and removal plan disagree across nested volumes.**

[ScanTargetRecordFacts.swift:122](/Users/rickb/dev/VideoScan/VideoScan/Volumes/ScanTargetRecordFacts.swift:122) excludes other-volume targets from overlap detection. [VideoScanModel+DeleteScanTarget.swift:165](/Users/rickb/dev/VideoScan/VideoScan/Volumes/VideoScanModel+DeleteScanTarget.swift:165) delegates to path-only overlap detection at line 177.

Concrete reproduction:

- Register `/Volumes` on volume A and `/Volumes/Projects` on volume B.
- Catalog one record `/Volumes/Projects/a.mov`, evidenced on B.
- `ScanTargetRecordFacts.records` for Projects is **1**.
- `planTargetRemoval` returns **0 IDs**, reporting the record as covered by `/Volumes`, despite that target being on A.

This violates invariant 4 and prevents removal of the target’s own record. Both paths need the same volume-aware overlap rule.

Regression assertion to add to `ScanLocationVolumeTests.swift` (not executed):

```swift
@Test func nestedDifferentVolumesMatchRemovalCount() {
    let parent = UUID(), child = UUID()
    let root = "/Volumes/Projects"
    let r = rec(root + "/a.mov", volume: ultra)
    let facts = ScanTargetRecordFacts.project(
        [r], targets: [(parent, "/Volumes"), (child, root)],
        targetVolumes: [parent: m4, child: ultra])
    let scope = TargetRemovalScope(
        root: root, allTargetRoots: ["/Volumes", root],
        volumeUUID: ultra)

    #expect(facts[child]?.records == [r].filter(scope.claims).count)
    // Current logic: 1 != 0.
}
```

Remaining scoped files:

- `VolumeIdentity+Record.swift`: read, no findings.
- `VolumeMediaTally.swift`: read, no findings.
- `CatalogView+ScanTargetsPane.swift`, requested call sites: read, no findings.
- `RecordVolumeEvidenceTests.swift`: read, no findings.
- `ScanLocationVolumeTests.swift`: read; missing the overlapping-volume case above.

Both named suites were attempted; **0 tests executed** because the read-only sandbox denied compiler/build writes. Reachability-helper internals are outside the permitted scope, so their network-I/O behavior remains unverified. No files changed.

Credits spent: unavailable | Finding count: 1  
Verdict: fix — make overlap ownership consistent between the Delete count and removal planner.

## Brief

# Codex brief — #401 scan location volume (P0, data-risk: removal scope)

SHA range: 1f2e1b48..eeb50f9d (one commit).

Workflow (one sentence): "A scan location shows, and removes, only the catalogued files that are on its own drive."

Files (do not explore outside these):
- VideoScan/VideoScanCore/Sources/VideoScanCore/VolumeIdentity+Record.swift (new)
- VideoScan/VideoScan/Volumes/VideoScanModel+DeleteScanTarget.swift (TargetRemovalScope, ScanTargetVolume, planTargetRemoval)
- VideoScan/VideoScan/Volumes/ScanTargetRecordFacts.swift (project, inSignatureScope)
- VideoScan/VideoScan/Catalog/VolumeMediaTally.swift (compute)
- VideoScan/VideoScan/Catalog/CatalogView+ScanTargetsPane.swift (only the recompute call sites, ~lines 180–205)
- Tests: VideoScan/VideoScanTests/ScanLocationVolumeTests.swift, VideoScan/VideoScanCore/Tests/VideoScanCoreTests/RecordVolumeEvidenceTests.swift

Invariants to attack:
1. A target-scoped removal (planTargetRemoval → TargetRemovalPlan.recordIDs) never claims a record whose evidenced volume is a different KNOWN volume from the target's mounted volume.
2. A record really on the target's volume is never dropped from its counts or its removal plan (stale scan volume after a move; auditSeenOn / fixity stamp outrank it).
3. Unknown volume on either side behaves exactly as before #401 (path rule) — no new refusal, no new claim.
4. The Delete menu count (ScanTargetRecordFacts.records) equals what planTargetRemoval would remove, for the same targets and volumes (the codex #1393 contract).
5. No filesystem I/O per record; target volume resolution never touches a network share or an unreachable path.

Evidence already run: touched suites 46 tests in 7 suites green (Debug); Core RecordVolumeEvidenceTests 6/6; red/green table in the commit; complexity gate OK; gauntlet inventory --validate 0 errors.

Output contract: findings with severity P0–P3, file:line, a concrete failing scenario; end with
`Credits spent: … | Finding count: N` and `Verdict: merge|fix|block`.
Do not explore outside these files.
