# Codex review — Delete-safety bundle #258 r5

- Range: `a5ae2c96..fix/258-delete-planner-honours-angel`
- Credits spent: unavailable
- Tokens: 212460
- Finding count: 6
- Verdict: block — five P1 findings remain; this bundle is not mergeable with only P2/P3 follow-ups.
- Run: 2026-10-04T01:34:49Z (cycle #38, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 6
Verdict: block — five P1 findings remain; this bundle is not mergeable with only P2/P3 follow-ups.

Reviewed `a5ae2c96..4cb59b04` against `8aa4acde`, without changing either checkout. The scoped worktree files match the tip. Findings are source-derived: Swift parsing confirmed the sensor counterexamples, but execution was blocked by compiler module-cache writes in this read-only session. The supplied passing tests and mutants remain separate evidence.

| Item | Round-5 result |
|---|---|
| R4-1 | **Reopened, P1:** archive candidates bypass the classification; older plans can lose it. |
| R4-2 | **Reopened, P1:** symlinked batches and leftover mount directories can still produce “free.” |
| R4-3 | Original lexical counterexamples **closed**; requested dead-call attack **reopened, P2**. |
| H | Fresh reading and one-hop implementation **closed**; “turning off never upgrades” **reopened, P1**. |
| L | Both declined UUID-probe cases have **P1** removal counterexamples. |
| M | **Fails:** branch can permanently delete a file main would Trash. |

1. **P1 — H/M: the recorded Trash preference is lost before phase two.**

   The decision samples the setting at `DeleteDuplicatesJob.swift:1314`, but [phase two samples it again at :1357](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift:1357). The final verdict combines only that second sample with the fresh setting. Its [evidence-change path at :466](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift:466) can therefore upgrade a recorded Trash.

   **Reproduction:** use three verified survivors, including a verified archive copy. Record `.trash` with the preference on. In `testHookAfterQuarantineSaved`, turn it off and make the fresh physical-device lookup become unknown, while every file stamp remains unchanged.

   **Branch:** changed drive evidence triggers redecision; preference is now false; the archive exception earns **permanent deletion**.  
   **Main:** unchanged stamps preserve the recorded **Trash**.

   The existing off-during-phase-two test retains a true second sample and misses this earlier window. Carry the preference that produced the recorded decision through phase two.

2. **P1 — R4-1/M: archive candidates bypass `notCountedWhy`, even in new plans.**

   [VideoScanModel+Duplicates.swift:839](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/VideoScanModel+Duplicates.swift:839) appends archive copies without consulting survivor standing. It adds their IDs to `seenArchive`, which excludes them from the later loop that applies `run.leftAlone`.

   **Reproduction:** start with K, targets A then B, and verified Review sibling S. During A’s phase-two read, give A promoted-copy provenance and valid archive fixity, with no Master Archive designation. The boundary holds A and records `notCountedWhy`. After put-back, verify A again.

   At B’s turn, A enters `archiveCopies` despite its explicit exclusion. K + S + A yield three survivors and the archive exception: **permanent deletion of B**. Main removes A and then **Trashes B** using K + S.

   Apply the run’s retained-row exclusion to archive candidates and promotion-linked copies before appending them.

3. **P1 — R4-1/M: older plans still make retained rows countable.**

   [DeleteDuplicatesPlan.swift:855](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesPlan.swift:855) recognizes legacy holds only for `.skipped`/`.refused` rows with a recognized note. A pre-field fresh archive refusal has neither the prefix nor the Read-only marker. It becomes `scope.decided`.

   **Reproduction:** run the round-4 late-designation scenario on `a5ae2c96`, retain A at its fresh archive boundary, and suspend before B. Resume that saved plan on this tip after removing the designation and verifying A again. With K + S on two devices, the resumed branch counts retained A and **permanently deletes B**; baseline behavior **Trashes B**. Removing S gives the corresponding leave-alone → Trash divergence.

   Legacy `.failed` rows retained after a protection-triggered put-back failure also miss the fallback after recovery. The new field correctly survives failed put-back in newly written plans; the compatibility path does not.

   The assertion at `DeleteDuplicatesCodex258Round4Tests.swift:312` actually confirms that the serialized-away classification disappears. Old captured and fresh archive refusals have identical notes, so ambiguous provenance must not silently authorize remaining deletions.

4. **P1 — L: unavailable UUID evidence can bypass both protections.**

   These are conditional failures after path protection misses, not a claim that every nil probe is unsafe.

   **Read-only:** [ReadOnlyVolumeProtection.swift:274](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/Archive/ReadOnlyVolumeProtection.swift:274) returns nil when the file’s UUID cannot be read.

   Mark `/Volumes/TestOld` with UUID U, then remount that drive as `/Volumes/TestNew`. Let UUID/resource lookup be unavailable while the files remain readable. Neither rebuilding the roots nor the removal-time identity check recognizes the new spelling; the gate permits removal. A synthetic identity seam returning the new mount, with UUID probes returning nil, reproduces this directly.

   **Archive:** [ArchiveVolumeProtection.swift:456](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/Archive/ArchiveVolumeProtection.swift:456) similarly returns `.clear`. Designate the external drive under its old path with UUID U, then mount it at a custom path outside `/Volumes`. With UUID lookup unavailable, the fresh protection remains unresolved, but both the custom-path verdict and UUID check return clear. An ordinary extra outside the archive tree can be removed from the archive drive.

   Ordinary unresolved `/Volumes` archive paths correctly return `.unprovable`; the custom-mount path is the counterexample. **Both declined items require fixing for this bundle.**

5. **P1 — R4-2: the fresh buffer reader still converts unreadable evidence into freedom.**

   Two concrete routes remain in [ArchiveAngelPlan.swift](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/ArchiveAngel/Prepare/ArchiveAngelPlan.swift:644):

   - **`:644`:** a `batch-` symlink is skipped. Put an unreadable or ready plan behind the only batch symlink, with published/in-memory sets empty. The fresh result is `.ids([])`, the façade answers `.free`, and otherwise eligible removal proceeds. Refusing traversal is appropriate; answering uncertainty would preserve that restriction.
   - **`:675`:** `bufferIsAbsent` checks whether `/Volumes/TestDrive` exists, rather than whether the drive is connected. A leftover mount directory after disconnection makes a missing buffer read as empty although its batches are on the disconnected drive. An alias into an absent `/Volumes` drive can also evade this lexical check.

   The ordinary listing, missing-plan, decoding and individual-plan permission failures now correctly become uncertain holds.

6. **P2 — R4-3: dead code still satisfies the named sensors.**

   [SourceTree.swift:192](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScanTests/SourceTree.swift:192) does not reject inactive conditional compilation, unused closures or ordinary literals containing expected call text.

   **Concrete mutant:** wrap the existing fresh-reader body in `#if false … #endif`, then return `.ids([])`. The principle sensor still sees the load, exactly three uncertainty returns, and no forbidden cache calls. Swift parsing accepted this mutant.

   Likewise, a gate inside an unused closure can satisfy a presence sensor. A single textual `onMainActor` call placed inside a two-iteration loop satisfies the one-hop count while executing twice.

   The lexical refusal fixes work. These sensors still establish textual presence rather than execution. **This is a follow-up issue, not independently a merge blocker.**

The remaining L audit results are:

| Input | Result |
|---|---|
| Model gone during the hop | Holds through `.catalogGone`, with `preferTrash` true. |
| Record left the catalog | Angel predicates are correctly asked by ID. |
| Main-actor hop | One production hop; no independent failure found. |
| Fresh drive lookup | Unknown evidence adds no drive. |
| Counted-copy stamps | Missing or changed stamps drop the copy. |
| New-plan settlement | Classification is written without an intervening await; stale dispatch snapshots conservatively exclude pending rows. |

Scoped sections **read, no findings** beyond the findings identified above:

- `ArchiveAngel.swift` — correctly propagates held/free/uncertain.
- `docs/practices/invariants/MediaOps.md` — policy read; implementation violations are identified above.
- Small edits in `DeleteDuplicatesCodex258HoldBoundaryTests.swift`, `DeleteDuplicatesCodex258Round2Tests.swift`, `ReadOnlyVolumeTests.swift`, `ArchiveProtectionFollowupTests.swift`, `DeleteDuplicatesAngelHoldTests.swift`, and `StewardSensorTests.swift`.

`DeleteDuplicatesCodex258Round3Tests.swift` and `DeleteDuplicatesCodex258Round4Tests.swift` were read; their relevant sensor and coverage gaps are identified above.

## Brief

Scoped data-risk RE-REVIEW (round 5) — delete-safety bundle (GH #258 + Read-only volumes + two-drives rule), 2026-10-03. Range a5ae2c96..fix/258-delete-planner-honours-angel (tip 4cb59b04; 3319206f is a merge of main that brought only docs and a Python prototype — ignore it). Round 4: docs/reviews/codex/codex-review-delete-safety-bundle-258-r4-2026-10-03.md (block, 3 findings). The branch's copy of docs/reviews/codex/codex-review-delete-safety-bundle-258-2026-10-03.md carries a "Findings closed" table through round 4. Read the branch via `git diff a5ae2c96..fix/258-delete-planner-honours-angel -- <path>`, `git show fix/258-delete-planner-honours-angel:<path>`, or the worktree .claude/worktrees/agent-ace49c157d541ff27. Do not check out the branch in ~/dev/VideoScan. Do not explore outside the files below. The "no weakening" baseline remains main's behaviour at 8aa4acde.

This is round 5 of a stop rule (two more rounds after round 4). Please be decisive: separate P1 data-loss findings from P2/P3 hardening, and say plainly if the bundle is now mergeable with P2/P3 follow-ups.

Files in scope:
- VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift — final verdict order (~413–452: captured Read-only check → one boundary ask (hold wins) → captured archive refusal (main's, countable) → fresh archive refusal (not countable)), `removalBoundary` (~1583, one main-actor hop ~1592), the uncertain-buffer hold (~1599), preferTrash fresh (~452), `runPair` writing `notCountedWhy`
- VideoScan/VideoScan/MediaOps/DeleteDuplicatesPlan.swift — `Entry.notCountedWhy` (additive), `setNotCounted`, `runScope` (~852: field first, note fallback for older plans)
- VideoScan/VideoScan/MediaOps/VideoScanModel+Duplicates.swift — `duplicateRemovalBoundaryNow` (~380), `authorizeDuplicateDeletion` `.skip(note:log:notCountedWhy:)`, the Angel's hold predicates asked by record id (~358, `duplicateAngelUseRule`)
- VideoScan/VideoScan/ArchiveAngel/Prepare/ArchiveAngelPlan.swift — `inFlightRecordIDsFresh` (~631–676) returning `.ids` / `.uncertain(why)`; `bufferIsAbsent` (~670)
- VideoScan/VideoScan/ArchiveAngel/Facade/ArchiveAngel.swift — the façade probe free / held / uncertain
- VideoScan/VideoScanTests/SourceTree.swift — `scan` returning code + unsupported constructs; `code(of:named:)` / `appCode(named:)` record an Issue and throw on them
- docs/practices/invariants/MediaOps.md (MOPS-2)
- Tests: VideoScanTests/DeleteDuplicatesCodex258Round4Tests.swift (new) and small sensor edits in the other DeleteDuplicatesCodex258* tests, ReadOnlyVolumeTests, ArchiveProtectionFollowupTests, DeleteDuplicatesAngelHoldTests, StewardSensorTests

Per round-4 finding, "closed" or re-open with a concrete reproduction (file:line; ideally a Swift Testing red test with synthetic data):
R4-1 — the rule as coded: a row this run planned as a target and then retained because of a protection found at its turn or at its removal boundary (an Angel hold; a Read-only mark; Angel evidence that could not be read; the Master Archive rule refusing it from the designation as it was AT THE REMOVAL where the check captured at its turn had let it go) is NEVER counted as a surviving copy for another copy of the run; rows decided on their merits (left alone by the tier, refused as not a duplicate, refused by the archive rule at the turn / by the captured check) keep main's treatment. Attack: any remaining route where a retained row is counted (resume of a plan written before `notCountedWhy` existed; a row whose put-back failed; a row retained for two reasons at once; the dispatch loop holding a stale copy of the plan while another row is decided); any input where the branch removes what main@8aa4acde would leave/refuse, or unlinks what main would Trash.
R4-2 — fail closed on unreadable Angel evidence: listing failure, batch folder without plan.json, undecodable plan, unexaminable preparing batch → uncertain → hold (not countable). A missing buffer folder counts as empty unless it sits on an unconnected /Volumes drive. Attack: any other way an error reaches "no hold" (permission on a single plan.json; a symlinked batch folder; the buffer root moved by settings; the record gone from the catalog — now asked by id).
R4-3 — code-only sensors now REFUSE regions containing constructs the stripper cannot read (`#"`, `#/`, comments inside `\(…)`, a `/` where an expression may begin). Attack: any remaining way a commented-out or dead call satisfies `theFinalVerdictCallsOnlyTheFreshEntryPoints`, `everyBulkVerbAsksTheGateWhereTheFileGoes` or the one-hop sensor (e.g. the call inside `#if false`, an unused closure, a string literal that is not a comment).
H — preferTrash read fresh in the same single hop; turning it on before the removal makes a recorded permanent Trash; turning it off never upgrades. A catalog gone during the hop holds with preferTrash on.

Also:
L. Fail-closed audit (the agent's table): Angel buffer; model gone during the hop; record left the catalog; the main-actor hop; fresh drive lookup (`.unknown` never adds a drive); counted-copy stamps; Read-only protection; archive designation. Two items were DECLINED as main's existing gate semantics: (1) the Read-only UUID probe returning nil is "no mark" (`ReadOnlyVolumeProtection.swift:274`, checked after the path and real-path tests); (2) the archive rule's external-volume UUID probe returning nil is "clear". Rate them: can either let a file on a Read-only or archive drive be removed by Delete Duplicates in a realistic case (e.g. a drive whose UUID cannot be read)? If yes, that is a P1 for this bundle, not a pre-existing nicety.
M. No-weakening re-check of the whole bundle as it now stands.

Known and accepted (do not report): hardware RAID = one device; two disks in one enclosure presenting as two devices count as two; two network shares on one server disk count as two; multi-store volumes keyed by the one store DiskArbitration reports (documented limit); the window between the final verdict and unlink(2)/trash; latency of the main-actor hop behind busy main-thread work (not a deadlock); keeper election and target eligibility sampled at the turn (main's behaviour); Catalog Rename and add-a-file verbs not blocked on a Read-only drive (ruling pending); the Angel's extraCopy exclusion is a switchable policy default; two-real-drives cases go through the identity seam; SwiftLint warnings; gauntlet manifest not regenerated.

Evidence already run (Debug, by suite, counts confirmed nonzero): final run after the main merge — 899 Swift Testing tests / 146 suites + 13 XCTest (4 skipped), 0 failures; 10 known issues (2 pre-existing in SourceTreeTests, 8 deliberate `withKnownIssue` in the new stripper-refusal tests). Round-4: R4-1 two scenario tests + a property test over 5 protection kinds × 2 fixtures red on a5ae2c96; R4-2 four tests red; R4-3 codex's inputs red; H red. Mutants: R4-1 3, R4-2 5, R4-3 5 (one first survived — a test gap, now pinned), H 2 — all red.

Output contract (required):
- First line exactly: Credits spent: <amount> | Finding count: <N>
- A line: Verdict: <merge | fix | block> — <one-line reason>

Wanted: "closed"/re-opened per R4-1..R4-3 and H; findings for L–M ranked by data-loss risk, each marked P1/P2/P3; "read, no findings" per clean file. Privacy: public repo — no real family names, addresses or dates in any suggested fixture.
