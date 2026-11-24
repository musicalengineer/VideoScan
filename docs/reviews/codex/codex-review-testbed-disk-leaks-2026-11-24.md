# Codex review — Testbed disk leaks

- Range: `origin/main..cb9e78de6`
- Credits spent: unavailable
- Tokens: 160472
- Finding count: 6
- Verdict: fix
- Run: 2026-11-24T17:46:38Z (cycle #360, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 6
Verdict: fix

Reviewed `cb9e78de6`; line numbers refer to that commit. Concurrent worktree edits are outside this verdict.

1. **[P1] Shard cleanup deletes DerivedData it never created.** [scripts/xctest_shards.py:987](/Users/rickb/dev/VideoScan-wt/disk-leaks/scripts/xctest_shards.py:987)  
   Failing input: supply a run directory containing `0000 -> outside`, with `outside/xcode-dd/precious` already present. Even when xcodebuild fails before allocating anything, cleanup calls `rmtree(run/0000/xcode-dd)`, reaching the external directory through its parent symlink. Neither the existing shard directory nor `xcode-dd` is claimed exclusively. **Mocked RED:** a failed launch still requests that deletion.

2. **[P1] Disk marking truncates hard-linked files.** [scripts/testbed_host.py:1501](/Users/rickb/dev/VideoScan-wt/disk-leaks/scripts/testbed_host.py:1501)  
   Failing input: hard-link `testbed-disk-mark.json` to a valuable regular file, then run `disk-mark`. `O_TRUNC` destroys the shared inode’s contents immediately; this write path never checks `st_nlink`. `O_NOFOLLOW` does not protect hard links. **Mocked RED:** the original contents become disk-mark JSON.

3. **[P1] The cache allowlist also accepts unauthorized `core-build` suffixes.** [scripts/testbed_host.py:280](/Users/rickb/dev/VideoScan-wt/disk-leaks/scripts/testbed_host.py:280)  
   Failing input: an eight-day-old `~/Library/Caches/videoscan-nightly-core-build-wt/uncommitted.swift`. The optional suffix applies to both regex alternatives, so `_stale_caches` selects this tree and `_aged` authorizes its deletion. The brief permits suffixes only after `-dd`. **In-memory RED:** the uncommitted file is deleted.

4. **[P1] Permission repair can follow a symlink outside the run.** [scripts/gauntlet/Runner.swift:688](/Users/rickb/dev/VideoScan-wt/disk-leaks/scripts/gauntlet/Runner.swift:688)  
   Failing interleaving: during the removal retry, replace a directory with a symlink after `lstat` succeeds but before `chmod`. Both `chmod` and the subsequent directory listing follow the replacement; recursion then changes external directories’ permissions. There is also no device check to stop permission repair at a mounted subtree. This violates the explicit confinement requirement. **Source-only finding.**

5. **[P1] Retention strips a live run once three newer runs exist.** [scripts/gauntlet/Runner.swift:777](/Users/rickb/dev/VideoScan-wt/disk-leaks/scripts/gauntlet/Runner.swift:777)  
   Failing input: four runner-owned directories started within the last hour, all unfinished, with no history rows. Run `--retain`. The oldest becomes a retention candidate, bypasses the finished-or-six-hour check, and reaches `removeBuildScratch` at line 786. Its active DerivedData, fixtures and sealed home are removed. **Source-only finding.**

6. **[P2] Shallow timestamps misclassify recently used caches as stale.** [scripts/testbed_host.py:769](/Users/rickb/dev/VideoScan-wt/disk-leaks/scripts/testbed_host.py:769)  
   Failing input: old ancestor timestamps but a freshly rewritten `videoscan-nightly-core-build/arm64-apple-macosx/debug/Widget.build/main.o`. The scan stops at `debug`; rewriting an existing descendant does not update ancestor mtimes. **In-memory RED:** cleanup deletes the freshly touched cache.

`scripts/corpus_run.py` and `scripts/run_gauntlet.sh`: **read, no findings**.

Validation: four mocked/in-memory RED probes; two cleanup controls, the existing shard-command test, floor/leak checks and shell syntax passed. Filesystem integration and Swift tests were not run because the sandbox is read-only. No files changed by me.

## Brief

# Codex review — testbed disk-leak fix (ONE round, DECISIONS 2026-11-23)

Test/tooling code that deletes files. Find ways it can delete something it does not own.

Scope (only these):
- scripts/testbed_host.py: Confine._aged / inside, _stale_caches, _old_logs, FLOOR 0.40, disk_mark/disk_leak.
  Must delete ONLY: ~/Library/Caches/videoscan-<x>-dd[-<y>], videoscan-<x>-core-build, ~/Library/Caches/VideoScan/<x>-dd
  untouched 7 days; ~/Library/Logs/VideoScan/coverage/*.xcresult and app-*.log older than 3 days; nightly_test_<stamp>.log
  (+ siblings) older than 7 days; always keeping the newest of each. Never through a symlink, never across a mount,
  never videoscan-runall, VideoScan/*-wt, corpus, App Support.
- scripts/gauntlet/Runner.swift: removeTree / makeOwnerWritable (chmod must not follow symlinks or leave the run root);
  retention (newest 3, <= 3 days, finished-or-6h runs lose regenerable folders; a run in progress is never touched).
- scripts/xctest_shards.py shard_cmd xcode-dd, scripts/corpus_run.py xcode-dd: frees exactly what it created.
- scripts/run_gauntlet.sh: module cache in $TMPDIR removed by trap.

Report concrete defects with file:line and a failing input. Ignore style.

## Output contract
Your answer's FIRST line must be exactly: `Credits spent: <amount> | Finding count: <N>`
and it must contain a line: `Verdict: <merge | fix | block>` followed by the findings.

## Closed

Closed by `8856be49a` at 2026-11-24T18:09:22Z.
