# Codex review — 401 scan location volume closing

- Range: `1f2e1b48..b9bcc6dc`
- Credits spent: unavailable
- Tokens: 44179
- Finding count: 0
- Verdict: merge
- Run: 2026-10-30T19:01:27Z (cycle #185, tools/codex_review.py)

## Codex answer

No findings. Cycle #184 is closed against invariant 4: both algorithms require exactly one distinct, volume-compatible containing root, including unknown volumes and duplicate normalized roots.

Independent predicate-model check: **127,080 comparisons, zero mismatches**; the previous overlap rule produced 3,848 mismatches.

Scoped files — read, no findings:

- `VolumeIdentity+Record.swift`
- `VideoScanModel+DeleteScanTarget.swift`
- `ScanTargetRecordFacts.swift`
- `VolumeMediaTally.swift`
- `CatalogView+ScanTargetsPane.swift` — recompute call sites
- `ScanLocationVolumeTests.swift`
- `RecordVolumeEvidenceTests.swift`

Swift suites were not rerun because the sandbox is read-only. The supplied 47-test and Core 6/6 results remain the execution evidence; the independent model checks predicate equivalence only.

Credits spent: unavailable | Finding count: 0  
Verdict: merge

## Brief

# Codex brief — #401 scan location volume (P0, data-risk: removal scope)

SHA range: 1f2e1b48..b9bcc6dc (closing round: cycle #184 P1 — nested targets on different drives — fixed in b9bcc6dc with nestedDifferentVolumesMatchRemovalCount, seen red then green; 47 tests in 7 suites green). Close the finding against invariant 4, not the example.

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
