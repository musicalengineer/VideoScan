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
