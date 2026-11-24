# Codex review — corpus shrink (apply-shrink deletion)

- Range: `origin/main..feat/corpus-sample`
- Credits spent: unavailable
- Tokens: 127260
- Finding count: 9
- Verdict: block
- Run: 2026-11-24T17:32:07Z (cycle #359, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 9

1. **P1 — Planning can overwrite media through its output file.** [scripts/corpus_shrink.py:311](/Users/rickb/dev/VideoScan-wt/corpus-sample/scripts/corpus_shrink.py:311)  
   Reproduction: make `<out>/shrink-plan.json` a symlink to a keeper, then run `plan-shrink`. Only the output directory is checked; `write_text` follows the link and truncates its target. A hard link also bypasses the protection. Create the output without following links or overwriting existing files.

2. **P1 — The opened media folder is not bound to the root proof.** [scripts/corpus_shrink.py:233](/Users/rickb/dev/VideoScan-wt/corpus-sample/scripts/corpus_shrink.py:233)  
   Reproduction: swap X10 after `Seal.external()` verifies its UUID but before `os.open`. The external proof is cached; both the opened descriptor and subsequent mount stat see the replacement device, so the check passes. Similarly, replacing a corpus ancestor with a same-device symlink after `seal.check()` lets `realpath` redirect the open outside the corpus.

3. **P1 — Case aliases bypass installed-sample protection.** [scripts/corpus_shrink.py:272](/Users/rickb/dev/VideoScan-wt/corpus-sample/scripts/corpus_shrink.py:272)  
   Reproduction on case-insensitive APFS: the sample names `Volumes/Drive/Keep.mov`; edit the plan to name `Volumes/Drive/keep.mov`, with a non-sample SHA and matching size. String comparisons miss the keeper, while filesystem lookup reaches and deletes it. Protection must account for filesystem identity.

4. **P1 — Size alone does not establish that the target is the dropped copy.** [scripts/corpus_shrink.py:209](/Users/rickb/dev/VideoScan-wt/corpus-sample/scripts/corpus_shrink.py:209)  
   Reproduction: replace a planned copy with unrelated bytes of the same length before applying. It is deleted: the planned SHA is never checked against the file. A hand-edited plan can likewise target an unmanifested regular file under media.

5. **P1 — The final filename can change between stat and unlink.** [scripts/corpus_shrink.py:211](/Users/rickb/dev/VideoScan-wt/corpus-sample/scripts/corpus_shrink.py:211)  
   Reproduction: replace the leaf immediately after its successful stat. `unlink` removes the replacement—even one of a different size. The inode recheck covers directories only; deletion is not bound to the verified leaf.

6. **P1 — The GREEN gate accepts insufficient or contradictory evidence.** [scripts/corpus_shrink.py:150](/Users/rickb/dev/VideoScan-wt/corpus-sample/scripts/corpus_shrink.py:150)  
   Independently reproduced acceptance of:
   - A `verbs` report stored under the check-lane directory.
   - `inventory={"internal":{}}` with positive `files`.
   - Missing engine evidence.
   - Malformed `against`, or `changed: 0` alongside recorded transitions.

   The gate never reads outcomes or reconciles coverage with the installed manifest. Validate run identity and complete outcomes, and verify the comparison rather than trusting summary fields.

7. **P1 — A run can record the hash of a manifest it never exercised.** [scripts/corpus_run.py:1944](/Users/rickb/dev/VideoScan-wt/corpus-sample/scripts/corpus_run.py:1944)  
   Reproduction: replace manifest A with B between `load_manifest()` and the separate `read_bytes()`. The run processes A but records B’s hash, allowing it to authorize B’s shrink plan. Parse and hash the same captured bytes.

8. **P1 — Deletions can finish without a receipt.** [scripts/corpus_shrink.py:288](/Users/rickb/dev/VideoScan-wt/corpus-sample/scripts/corpus_shrink.py:288)  
   Reproduction: pre-create the history file as a symlink. Files are deleted before the guarded receipt write refuses. Separately, put a valid deletion before a place containing `\u0000`: validation accepts it, stat raises uncaught `ValueError`, and the earlier deletion receives no receipt. Preflight entries and receipt access, and preserve partial outcomes on failure.

9. **P2 — Moving previously ingested content to `ro` breaks preparation.** [scripts/corpus_run.py:1309](/Users/rickb/dev/VideoScan-wt/corpus-sample/scripts/corpus_run.py:1309)  
   Reproduction: retain an old ledger entry with `status="ok"` and change that digest’s manifest root to `ro`. Its `not_run` state still admits it to catalog construction; verification then refuses with `outside_corpus=1`. Exclude `ro` entries regardless of cached ingest status.

Verification: **15 in-memory adversarial checks failed as expected; six controls passed.** These simulated filesystem races and aliases; no real media was touched. The named suite’s **29 tests all errored because the read-only sandbox prevented temporary-directory creation**.

`tests/test_corpus_shrink.py`: read, no isolation findings. Its success fixture omits the installed `ro` row from reported coverage, masking finding 6. No repository files changed.

Verdict: block

## Brief

# Codex review brief — corpus shrink: the one deletion on the M4's corpus roots (data-risk, one round)

Range: main..feat/corpus-sample. Scope: `scripts/corpus_shrink.py` (new, the deletion) and the parts of
`scripts/corpus_run.py` it trusts (`Seal.check`, `Seal.external`, `lane_runs`, `clean_report`'s new
`manifest_sha256`, `verdict_of` with the new `not_run_ro`). Tests: `tests/test_corpus_shrink.py`.
The sampling rule (`scripts/corpus_select.py`) is test tooling and NOT in scope except where it feeds the plan.

Context (DECISIONS 2026-11-24): the M4 holds COPIES of real family media under two roots — `~/corpus/media/<original
path less its slash>` on the SSD and `<adopted X10 mount>/corpus/media/<…>` on an external volume pinned by UUID. The
corpus becomes a ~12% stratified sample; "shrinking the copy deletes a dropped file only after a run on the new sample
is green; originals are never touched". Originals live on the Ultra's drives (`/Volumes/<Drive>/…` on another Mac),
never on the M4; on the M4 an original path appears only as a place under a root's media folder.

Claim:
- `plan` is read-only: it lists rows of the previous manifest whose (sha, root) and (root, place) the sample does not
  hold, and whose copy is a regular file of the manifest's size.
- `apply` deletes nothing unless: the seal passes (M4 hostname, marked ~/corpus, its folders themselves); the manifest
  installed in ~/corpus is byte-identical (SHA-256) to the plan's sample; `--after-green <stamp>` names exactly one
  stored check-lane run that is GREEN, not SMOKE/--limit, read that same manifest (`manifest_sha256` in its report),
  and saw every manifest file `present` (no missing / not_run / problem state in any root).
- Every root the plan names is proven and its media folder opened BEFORE the first unlink (a wrong volume at the X10's
  mount refuses the whole step with nothing deleted).
- Each file: the place must be `Volumes/…` with no empty, `.` or `..` component; the walk is openat with O_NOFOLLOW
  per folder, stat(follow_symlinks=False), same device as the media folder, ino re-checked after open; the file must be
  S_ISREG, one link, no immutable/append flag, the planned size; unlink by dir_fd; then empty parent folders up to but
  never including the media folder. A file the installed sample names (by sha on that root or by place) is never
  deleted, whatever the plan says. The `ro` root is never deleted from.

Review adversarially:
1. Can any input (a hand-edited plan, a poisoned report.json, a symlink or mount placed anywhere under ~/corpus, the X10
   swapped or unmounted mid-run, a hard link, a case-insensitive APFS name collision) make `apply` unlink a file that
   is (a) outside a root's media folder, (b) a copy the installed sample still names, or (c) not a copy at all?
2. Is the GREEN gate sound? Could a run that did not exercise the installed sample (an older manifest with the same
   bytes, a stale report, a report from another lane, `against` poisoned to hide a change) pass `green_run`?
3. Is anything left half-done in a way that loses evidence (no receipt when some files were deleted; a Refused mid-loop
   after deletions)? Is the receipt written safely?
4. The `ro` root in corpus_run.py: any path where an `ro` row is opened, hashed, built into the sealed catalog, or lets
   a run be GREEN / accepted / the implicit baseline?
5. Isolation of the tests: any write outside their temporary folders; any real path or real catalog opened?
Out of scope: the sampling percentages and budgets (Rick's ruling), the docs.

## Output contract
First line of your answer exactly: `Credits spent: <amount> | Finding count: <N>`
Then findings (file:line, failure scenario, severity), then a line `Verdict: <merge | fix | block>`.

## Closed

Closed by `1bdb50964` at 2026-11-24T17:52:36Z. 9 of 9 addressed, each with a red-first test; one round per brief, no second Codex pass
