# Codex review — diskfull ballast fd leak (test-only)

- Range: `main..fix/diskfull-space-returned`
- Credits spent: unavailable
- Tokens: 53675
- Finding count: 0
- Verdict: merge
- Run: 2026-10-28T00:57:17Z (cycle #160, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 0

- `CatalogDiskFullTests.swift` — read, no findings.
- `CatalogWriteCornerDiskTests.swift` — read, no findings.

The regression isolates descriptor inheritance without opening a catalog or WAL. Atomic `O_CLOEXEC` addresses that mechanism. The commit records RED without it and 50/50 GREEN afterward; this supports the explanation, though it does not conclusively identify the original gauntlet child.

The disk-word refusal, unchanged generation/old notes, and successful retry assertions remain intact. `returnSpace` only removes ballast and polls measured free space every 10 ms. Its 90% threshold and 30-second deadline neither repair catalog state nor retry a failing commit; unreclaimed ballast causes a fixture failure.

Child cleanup targets a positive, unreaped PID, preventing PID reuse before cleanup, and retries `waitpid` on interruption. All successful-spawn paths reach cleanup. Test-controlled writes remain within the temporary directory/image.

The five-second regression deadline retains some scheduling/I/O flake risk under extreme load; its margin is not independently verified here.

Validation: scoped tests were attempted, but Swift failed before execution because the read-only sandbox denied toolchain cache access. **0 tests executed independently.** Static diff checks passed. Known-issue cases were excluded as requested.

Verdict: merge

## Brief

# Codex review brief — disk-full test flake (test-only)

Range: main..fix/diskfull-space-returned (one commit, 80c07f02). Two files under
VideoScan/VideoScanCore/Tests/VideoScanCoreTests/Store/.

Claim: gauntlet run on the M5 Ultra failed `CatalogDiskFullTests` (`full` depth)
with ENOSPC on retry after "space returns". Root cause per the author: the
ballast file in `DiskImageVolume.fill` was opened without O_CLOEXEC; a child
process spawned by another parallel suite inherits the fd, so the unlinked
ballast keeps its blocks until that child exits. Fix: O_CLOEXEC on the ballast;
new `returnSpace(_:within:)` deletes the ballast and polls statfs until ≥90% of
its bytes are free (deadline 30 s, throws with the free bytes); regression test
`ballastIsNotInheritedByChildren` spawns a sleeper while the fd is open.

Review adversarially:
1. Is the mechanism proven, or could the fix merely mask a real catalog-store
   bug (e.g. the store itself holding the ballast or the WAL growing)? Does the
   test still prove what its name says: the commit is refused with the disk's
   words, the old state stays, the same edits land after space returns?
2. Can `returnSpace` hide a production failure (the 90% threshold, the 30 s
   deadline)? Is it a condition wait, not a sleep?
3. Regression test: does it kill and reap only its own child, never leak a
   process, never touch anything outside its disk image? Any flake risk of its
   own (5 s deadline under heavy parallel load)?
4. Isolation: any write outside the per-test disk image/temp dir?
Out of scope: the withKnownIssue cases; POSIX_SPAWN_CLOEXEC_DEFAULT across
Core (will be filed separately).
## Output contract
First line of your answer exactly: `Credits spent: <amount> | Finding count: <N>`
Then findings (file:line, failure scenario, severity), then a line `Verdict: <merge | fix | block>`.
