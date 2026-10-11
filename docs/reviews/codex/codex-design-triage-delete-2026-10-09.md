Credits spent: unavailable (billing telemetry not exposed) | Finding count: 9
Verdict: revise — the workflow is sound, but selection authority and engine policy need explicit changes.

Read the full design and the five permitted engine files within scope. No files written or tests run. Verification primitives, authorization helpers, forecast implementation, and Excess survivor checks are outside the permitted files; their correctness remains unverified here.

1. **P1 — Counted IDs are necessary but insufficient for safe junk deletion.**

   Reproduction: open the sheet, mark another file Confirmed, then execute. `makeOnAct` re-queries all confirmed junk, widening the set ([JunkDeleteAction.swift:85](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/JunkDeleteAction.swift:85)). Alternatively, revoke a counted file’s junk status or replace its pathname: the engine does not enforce disposition, and the ordinary action supplies no guard ([VideoScanModel+JunkDelete.swift:192](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/VideoScanModel+JunkDelete.swift:192)).

   **Smallest safe shape:** freeze deduplicated IDs, expected paths, file identities, and displayed sizes when preparing the sheet. Execute only that snapshot. Recheck live Confirmed status, identity, reachability, and protections at each file’s turn; changes become named holds. Never substitute the current occupant of a counted pathname. The existing `authorize`/`beforeRemoval` callbacks provide useful seams, but authorization currently occurs before the entire detached batch ([same file:282](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/VideoScanModel+JunkDelete.swift:282)); it needs per-file freshness.

2. **P1 — Explicit pairs fit the plan; the existing launch path does not preserve the UI’s selection.**

   Entries already carry target and keeper IDs/paths ([DeleteDuplicatesPlan.swift:666](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/DeleteDuplicatesPlan.swift:666)). However, a fresh job calls `prepareDuplicateDeletion(onVolume:)`, rebuilding its input ([DeleteDuplicatesJob.swift:925](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift:925)).

   Add a fresh-job entry point accepting the exact reviewed plan. For minimum disruption, partition the frozen selection into sequential per-volume plans; retain one fixed keeper per group across the entire batch. No keeper may also be a target, including through aliases.

   Arbitrary keeper overrides are **not** drop-in reuse: cross-volume cleanup requires a known, online, non-retired, strictly higher-ranked keeper ([DuplicateKeeperPolicy.swift:226](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/DuplicateKeeperPolicy.swift:226)). Initially restrict overrides to eligible choices. Supporting lower-ranked keepers requires an explicit authorization-policy change, never bypassing verification.

3. **P1 — Removing permanent buttons does not establish Trash-only behavior.**

   Junk still exposes `.permanent` and calls `removeItem` ([VideoScanModel+JunkDelete.swift:402](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/VideoScanModel+JunkDelete.swift:402)). Duplicate phase two converts recorded tiers into permanent disposal and can proceed with that choice ([DeleteDuplicatesJob.swift:395](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift:395), [458](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift:458)).

   Make Trash-only an execution rule, including resumed legacy plans; a preference default is insufficient. Keep old permanent enum values decodable for history, but never executable in these flows.

   Preserve quarantine persistence, cancellation, live protections, and recovery. A Trash failure must never fall back to unlink. Junk already catches the error; duplicates expose both failure and retained-quarantine outcomes ([job:528](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift:528)). A stranded file requires a visible recovery action, not merely “held back.”

4. **P1 — The invariant contract promises more than this reuse establishes.**

   §6.1 cannot apply to junk: that engine explicitly allows deleting unique, human-confirmed junk without a backup or duplicate check ([VideoScanModel+JunkDelete.swift:15](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/VideoScanModel+JunkDelete.swift:15)). Scope keeper proof to duplicate disposal.

   Also replace “nothing moves unless proven” with “nothing is disposed of unless proven”: the single-read duplicate path quarantines the target **before** hashing it ([DeleteDuplicatesJob.swift:332](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift:332)).

   Archive and read-only checks are wired into removal, but blanket network exclusion, archive-backup protection, longer-than-master protection, and A/V-half protection are not established by the permitted implementations. Name their required execution gates explicitly. Keeper precedence is election policy, not target protection; selecting an SSD keeper must never make the archive selectable.

5. **P2 — “Keep 1” currently holds the very files the UI offers.**

   Reproduction: two identical files, one keeper, one target. `minimumForTrash == 2` means **two surviving copies**, and its guard runs before `preferTrash` ([DeleteDuplicatesPlan.swift:557](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/DeleteDuplicatesPlan.swift:557), [583](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/DeleteDuplicatesPlan.swift:583)). The worker can reject the pair before hashing for the same reason ([DeleteDuplicatesJob.swift:311](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift:311)).

   Explicitly change the survival policy to one independently verified keeper for Trash. Update early eligibility, final decision, boundary recheck, forecast, and sibling-read goals together. This reduces redundancy requirements; it need not weaken digest or identity verification.

   Retain the existing pair-verification calls. Copy-count “tiers” are disposal decisions, not evidence that a displayed group contains identical content.

6. **P2 — Refusals can disappear before the result banner receives them.**

   Junk archive filtering removes records before constructing the result; an entirely protected selection returns `attempted: 0`, with no refusals ([VideoScanModel+JunkDelete.swift:176](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/VideoScanModel+JunkDelete.swift:176)). Offline and missing results retain counts but no per-item lists. Duplicate pre-plan skips include an aggregate count, while the detailed held list is capped at 2,000 ([DeleteDuplicatesPlan.swift:774](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/DeleteDuplicatesPlan.swift:774), [838](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/DeleteDuplicatesPlan.swift:838)).

   Return one outcome per requested ID, including preflight exclusions. Display large result lists lazily; do not truncate their underlying reasons. Remove rows only after confirmed success, with missing, failed, held, and recovery-needed outcomes distinguishable.

7. **P2 — Counts and “reclaimable” bytes have conflicting meanings.**

   The mockup says “save 123 GB” while only 82 GB is selected. §6.6 cannot mean successful moves equal the initial count: a drive can disconnect after confirmation. Define:

   **Frozen requested set = moved + held + failed + missing + cancelled**, with mutually exclusive outcomes.

   Junk’s current byte figure scales total bytes by successful **file count** ([JunkDeleteAction.swift:99](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/JunkDeleteAction.swift:99)). One tiny success and one huge failure therefore report a false byte total. Sum successful files’ measured sizes instead.

   Duplicate accounting already separates trashed bytes from freed bytes ([DeleteDuplicatesJob.swift:1517](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift:1517)). Preserve that distinction: label the UI “selected bytes” or “bytes moved to Trash,” not space already reclaimed.

8. **P2 — Undo is a separate recovery feature, not a resulting-URL convenience.**

   Both engines discard the Trash location: junk leaves `resultURL` local; duplicate settlement ignores `location` ([VideoScanModel+JunkDelete.swift:407](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/VideoScanModel+JunkDelete.swift:407), [DeleteDuplicatesJob.swift:1527](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift:1527)).

   Apple documents the resulting URL as the new Trash location and documents Finder’s Put Back operation, but those are not a universal app-level undo guarantee across APFS/HFS+/ExFAT. ([Apple API explanation](https://developer.apple.com/videos/play/wwdc2019/701/), [Finder recovery instructions](https://support.apple.com/guide/mac-help/delete-files-and-folders-on-mac-mchlp1093/mac))

   **Promise “Open Trash” initially.** Reliable app restoration needs original-path and identity records, mounted-drive checks, collision refusal, partial results, and catalog/ignore-list reconciliation. Duplicate recovery must restore the original path, not its intermediate quarantine path.

9. **P2 — Four overlapping selection controls exceed the one-sentence workflow.**

   Chips, copy checkboxes, keeper overrides, and “Keep 1 each” create precedence questions. Reproduction: uncheck RAID, then invoke bulk “Keep 1”; does it silently reselect RAID?

   Use one authoritative target set. Chips bulk-toggle eligible checkboxes; keeper changes clear that copy’s selection; bulk executes exactly the visible selections. Label it **“Move selected extras to Trash.”** Protected copies may mean more than one remains.

   Cut arbitrary keeper overrides, custom Undo, size/count-dependent confirmation skipping, and Excess-pane retirement from the first release. Keep one confirmation and one persistent result banner.

For §6 specifically: **1** is duplicate-only, with verification delegated and survivor alias deduplication visible at [Plan:352](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/DeleteDuplicatesPlan.swift:352); full alias safety cannot be certified within scope. **2** requires the frozen-plan handoff. **3** is partially wired, not fully demonstrated. **4** requires execution changes. **5** requires complete per-item outcomes. **6** needs the requested-set reconciliation definition above.