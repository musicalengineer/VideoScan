# Codex review — Cleanup KISS design

- Range: `31e70704d^..31e70704d`
- Credits spent: unavailable (billing telemetry not exposed)
- Tokens: 67809
- Finding count: 7
- Verdict: fix — the page is simple enough; the proposed instant proof is weaker than the existing contract.
- Run: 2026-10-12T15:52:12Z (cycle #64, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (billing telemetry not exposed) | Finding count: 7

Verdict: fix — the page is simple enough; the proposed instant proof is weaker than the existing contract.

Read all seven permitted files. No files written or tests run. #143’s engine contract is accepted. The 10/09 review and tab charters were read, no independent findings; settled safeguards below are carried forward, not reopened.

1. **P1 — Unchanged size, mtime and inode do not prove unchanged bytes. V1: required.**

   [Plan:34](/Users/rickb/dev/VideoScan/docs/design/cleanup_kiss_2026_10_12.md:34) omits **ctime and persistent volume UUID**, both required by [ContentFixity:290](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/ContentFixity.swift:290).

   | Scenario | Proposed check | Existing ContentFixity binding |
   |---|---|---|
   | Same-size in-place rewrite preserving mtime | Can pass | Catches changed ctime on filesystems providing reliable change times |
   | Rewrite followed by `touch -r` | Can pass | Same ctime protection |
   | Restore tool preserving size/mtime | Can pass if inode survives | Ordinary restore caught by inode/ctime; restoring filesystem metadata wholesale is outside that guarantee |
   | Delete/re-create with reused inode and restored mtime | Can pass | Normally caught by ctime; no independent inode-generation field |
   | Different, same-named volume | Can pass | UUID mismatch rejects it; duplicated UUID plus matching metadata is not distinguished |
   | Network/exFAT with weak identity or timestamp semantics | Can pass | Missing UUID rejects; supplied UUID/ctime are trusted without a filesystem-capability check |
   | APFS clone | Cloning alone creates no differing-byte failure | Replacement normally changes inode; later ordinary writes change ctime. Shared blocks do not make two files identical forever |

   Silent content corruption can also leave every stamp field unchanged.

   **Smallest robust rule for this invariant:** stored hashes identify candidates; freshly read **both files** before disposal, compare full SHA-256 and lengths, and check descriptor/path identity before and after. Skip changed or unreadable files. Reading only the survivor misses a changed target; reading only the target misses a corrupted survivor.

   The existing contract already says the target is always reread ([ContentFixity:69](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/ContentFixity.swift:69)). Keeper-cache reuse is an optimization with narrower assumptions, not universal proof. Defer filesystem-specific shortcuts.

2. **P1 — Keeper selection must apply to the entire run. V1: required.**

   Scenario: A names B as keeper while B is selected under Junk, or separate per-drive plans select each other. Both can disappear despite locally valid pair decisions.

   Carry forward the 10/09 settlement: freeze one deduplicated target set and one reserved survivor per exact-content group. Survivors cannot occur anywhere in the target set, including Junk or aliases; other app operations must respect that reservation. Exclude actual Trash locations as well as marked rows.

   [Plan:31](/Users/rickb/dev/VideoScan/docs/design/cleanup_kiss_2026_10_12.md:31) must require fresh keeper reachability and identity at each move. If either drive disappears, hold affected targets; never elect another selected target automatically.

   If both drives disconnect, stop affected work. No cross-drive check can atomically guarantee against a physical unplug concurrent with Trash, or guarantee future connectivity. State that execution boundary honestly.

3. **P1 — Two paths can represent one file. V1: required.**

   Scenario: `/Volumes/Media/clip.mov` and a path through `~/Movies` identify the same directory entry. Trashing it leaves the supposed keeper pointing nowhere. Case variants have the same problem. A symlink can also disguise FamilyArchive or Trash ancestry.

   **Fix:** compare opened-file identities, resolve ancestry, and count physical objects rather than catalog rows. For v1, exclude same-inode pairs and symlink-traversing targets from automatic cleanup. Distinct hardlinks can leave one name intact, but skipping them avoids alias mistakes and misleading space estimates.

   [ContentFixity:202](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/ContentFixity.swift:202) supplies a same-operation device/inode comparison; it does not itself enforce this run policy or reject symlinks.

4. **P1 — Junk is an explicit exception to the stated invariant. V1: resolve before building.**

   [Plan:13](/Users/rickb/dev/VideoScan/docs/design/cleanup_kiss_2026_10_12.md:13) permits marked junk without a survivor. A unique FamilyArchive recording accidentally marked junk demonstrates the contradiction.

   This was settled on 10/09 as **duplicate-only survivor proof**. Carry that distinction into this plan explicitly, or exclude unique junk under the literal invariant.

   A per-run checkbox is a reasonable authorization shape **only for that explicit exception**. Label it “Include these N marked-junk files from FamilyArchive”; show the exact files, default off, freeze selection, recheck their current junk status, and reset after the run. It must never unlock copy trimming. My simplest v1 recommendation: keep FamilyArchive locked and defer this exception.

5. **P2 — Backfilling hashes does not turn yesterday’s groups into proofs. V1: required.**

   Scenario: two sampled matches receive different full hashes overnight but remain classified as extras.

   [DuplicateDetector:225](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/DuplicateDetector.swift:225) groups using sampled hashes and metadata; keeper election delegates to `DuplicateKeeperPolicy` ([425](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/DuplicateDetector.swift:425)). The specified RAID/HDD/SSD/LaCie ordering cannot be verified from this file alone.

   **Fix:** build Cleanup groups directly from full SHA-256 plus byte count, then elect among eligible connected members. Missing/stale/unreadable evidence remains “not verified,” not “not a copy.”

   Both backfill files were read, no independent findings in the inspected orchestration. They delegate hashing/storage, save with acknowledgment, and explicitly omit regrouping ([FullHashBackfillJob:12](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/FullHashBackfillJob.swift:12)). Delegated implementations were outside scope. Recalculate the 867-file estimate; do not infer proof for the 115 missing or 774 untouched rows.

6. **P2 — Byte equality does not preserve editing dependencies. V1: exclude these targets.**

   Scenario: an Avid bin references the working MXF that Cleanup removes; an identical archive file survives, but the sequence goes offline.

   **Fix:** exclude Avid MediaFiles from v1 automatic trimming. Enforce the existing A/V-half exclusion at execution for both Copies and Junk; a duplicate half elsewhere does not establish preserved pair relationships. No relinking machinery is needed now. [Plan:48](/Users/rickb/dev/VideoScan/docs/design/cleanup_kiss_2026_10_12.md:48)

7. **P3 — Keep ties excluded; add outcomes, not more controls. V1: yes.**

   Leaving the 587 GB of keeper ties out is safe and simple. It sacrifices cleanup coverage, not safety; FamilyArchive remains protected regardless of ranking.

   Carry forward the settled selection/accounting rules: one frozen selection, progress/Stop, and a persistent result showing moved, held, failed, missing and cancelled files. Otherwise a disconnected drive makes the changing numbers inexplicable. Label GB as **selected bytes**, never space freed by moving to Trash.

   Keep “Not checked yet” informational. Retain a compact exclusion explanation; defer tie overrides and move the unrelated Events discussion out of this design.

Rules for v1 I would sign off on:

1. Full hashes find candidates; fresh reads of both files establish disposal proof.
2. Reserve one connected, outside-Trash survivor, excluded from every removal set.
3. Reject ambiguous identities, aliases, changed files and lost connections.
4. Protect FamilyArchive, A/V halves and Avid MediaFiles; leave ties untouched.
5. Execute the frozen selection through #143; retain rows and report every outcome.

## Brief

# Codex brief: Cleanup, from scratch (KISS): design review, before any code

**Answer contract.** The first line must be `Credits spent: <amount> | Finding count: <N>`. Include a line `Verdict: <merge | fix | block> …`, where "merge" means the design is sound enough to build. Write no files; answer only. Stay under about 1,200 words.

**Rick's ask (2026-10-12):** "a KISS simple but reliable and robust plan for cleanup." The delete work grew tangled: six doors, five Trash engines, numbers that kept changing. Last night we went back to basics. Every active catalog file on a connected drive now has a stored full SHA-256 (Fill In Full Hashes: 9,738 hashed, 115 missing at their path, 774 archived rows left alone). This is a **design review**: attack the plan, not code style.

**Read only these:**
- `docs/design/cleanup_kiss_2026_10_12.md` (the plan under review)
- `docs/design/tab_charters.md` (where Cleanup lives, and its rules)
- `docs/reviews/codex/codex-design-triage-delete-2026-10-09.md` (your 10/09 design review of the Triage delete; only to avoid re-raising what was settled)
- To check the plan's claims against the engines it reuses:
  - `VideoScan/VideoScanCore/Sources/VideoScanCore/ContentFixity.swift`: what a stored full hash binds to (size, mtime, inode, volume identity?)
  - `VideoScan/VideoScan/MediaOps/DuplicateDetector.swift`: the keeper rule
  - `VideoScan/VideoScan/MediaOps/FullHashBackfill.swift` and `FullHashBackfillJob.swift`: how hashes were stored last night

**Do not explore outside these files.** The one-removal-marker / one-Trash-engine work (#143) is on an unmerged branch; take its contract as given: one engine, Finder Trash only, a marker on every row, rows never deleted.

**Invariant to attack:** *No file goes to the Trash unless an identical copy provably stays, on a connected drive, outside the Trash, and is not itself being removed in the same run. FamilyArchive is never trimmed as a copy.*

**Questions, in priority order:**
1. **The delete-time proof (Rick's open question 1).** The plan proposes: stored full hash on both files, plus size, mtime and inode unchanged since hashing, gives instant proof; re-read only when anything differs. Is that sound?
   - Name concrete ways it passes while the bytes differ: in-place writes that preserve mtime, `touch -r`, restore tools, inode reuse after delete and re-create, a volume swapped for a same-named one, network or exFAT volumes with coarse or absent inode semantics, APFS clones.
   - For each one, say whether ContentFixity's existing binding already catches it.
   - Recommend the smallest rule that is still robust. For example: re-read the *surviving* copy only, or re-read only on certain filesystems.
2. **Run-level hazards:**
   - two files each chosen as the other's keeper;
   - a keeper that is also a candidate in the same run;
   - the last two copies both on drives that go offline mid-run;
   - a hardlink or the same inode reached by two paths, including case-insensitive paths and symlinked folders (last night's dry run found 27 symlinks from ~/Movies into the media drives);
   - A/V pair halves;
   - Avid MediaFiles.
3. **Is anything missing that a simple page still needs?** Is anything in the plan unnecessary?
4. **Keeper "ties" (about 587 GB, mostly copies inside FamilyArchive).** Is "leave them out" safe and simple enough for v1?
5. **FamilyArchive junk (Rick's open question 2).** Is a per-run "Unlock FamilyArchive" checkbox, off by default, a sound shape?

**Output:** findings ranked P1 (could trash the last good copy), P2 (wrong or confusing result), P3 (simplification). For each finding: the hazard, a concrete scenario, the smallest fix, and whether it belongs in v1. End with a five-line "rules for v1" list you would sign off on.

## Closure (Manager, 2026-10-12)

All 7 findings accepted into `docs/design/cleanup_kiss_2026_10_12.md` v2 (design only — pinning tests come with the build):
1. Stat-only proof dropped → fresh full read of BOTH files at each move (rule 1).
2. One frozen selection, one reserved survivor per full-hash group; keeper loss holds, never re-elects (rule 2).
3. Aliases/same-inode/symlink-traversing/case variants skipped; physical-object accounting (rule 3).
4. Junk taken out of Cleanup v1; FamilyArchive junk = Rick's open question (default: stay locked).
5. Groups built from full SHA-256 + size, not sampled-hash groups (rule 2).
6. Avid MediaFiles + A/V halves excluded at execution (rule 4).
7. Ties excluded; persistent outcome report; "GB selected" wording (page + rule 4).
