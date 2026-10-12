# Cleanup, from scratch (KISS)

**Status:** v2. Revised after the codex design review (`docs/reviews/codex/codex-design-cleanup-kiss-2026-10-12.md`, verdict "fix", 7 findings, all accepted below). Rick's FamilyArchive-junk ruling recorded (option b). No code yet.
**Premise (Rick 10/11):** back to basics. Every catalog file has a stored full SHA-256; nightly on 10/11, 9,738 were hashed. A file without one is never deleted. Cleanup only centralizes logic we already have.

## The one question

Triage ▸ Cleanup answers: **"Which files are extra, and can go to the Trash?"**

A file is *extra* when an identical copy stays somewhere else. Only copies, unsure files, A/V pair halves and Avid media are not extra, so they are not in Cleanup at all.

## The page: one table, one button

| | Files | GB selected | |
|---|---|---|---|
| ☑ **Copies**: identical full SHA-256, one copy stays | n | GB | See files… |
| **Not checked yet**: no full hash yet (information only) | n | GB | Fill In Full Hashes… |

Under the table: **Move N files (X GB) to the Trash…** That starts one MFO job. It shows progress, Pause/Stop, and a result that stays on screen: moved, held, failed, missing and cancelled, with a reason for each file. The GB figure is "selected", not "freed": nothing is freed until you empty the Trash yourself.

"See files…" lists the files. Unticking a file there leaves it out of this run.

## v1 rules (codex signed off on these five)

1. **Full hashes find the candidates; a fresh read of both files is the proof.**
   - The page uses stored full hashes, so it opens instantly.
   - At the moment of each move, the job reads the extra copy and the copy that stays, in full, and compares SHA-256 and length. It checks each file's identity (device and inode) before and after the read.
   - If anything differs or can't be read, that file is held and named.
   - This is Rick's standing rule: prove the surviving copy at delete time. For the 867-file set that's about 1.25 TB, roughly 1–1.5 h, so run it while away or overnight.
   - No stat-only shortcut. Codex showed size, mtime and inode can all be unchanged while the bytes differ.
2. **One reserved survivor per group, for the whole run.**
   - Groups are built straight from full SHA-256 plus size, not from yesterday's sampled-hash groups.
   - The selection is frozen when the job starts. Each group gets exactly one copy that stays, and it is never in the removal set, under any path.
   - If the drive with the copy that stays goes away, that group's files are held. Another file is never promoted to stand in as the copy that stays.
3. **Ambiguous identity means skip.** That covers:
   - two catalog paths that are the same file: same device and inode, hardlinks, case-only differences;
   - any path that runs through a symlinked folder (e.g. the 27 links from ~/Movies);
   - changed or unreadable files;
   - a drive that disconnects mid-run.
   Space is counted per physical file, not per catalog row.
4. **Never touched:**
   - FamilyArchive, which is never trimmed as a copy;
   - A/V pair halves;
   - Avid MediaFiles folders, because their bins would go offline;
   - keeper ties (about 587 GB, mostly copies inside FamilyArchive), which are left alone in v1.
5. **One engine:**
   - the frozen selection goes through the #143 Trash engine;
   - Finder Trash only, and the Trash is never emptied;
   - every row gets the "In the Trash" marker, and rows are never deleted.

## What this removes from today's code

- The footer "hidden" caption, Show Again, and the review sheet.
- The Storage card, Steward, and Copies & Advice delete doors. They become links to Cleanup.
- CheckCopies' "unsure" tier.

## Junk is a different question

"Junk you marked" has no surviving copy, so it falls outside rule 1 by definition. On 10/09 we settled that the survivor proof applies to *duplicates only*. Codex's simplest v1 leaves junk out of Cleanup entirely. Junk stays where it is today, as Triage ▸ Delete Junk, except on FamilyArchive, where it is blocked.

**Decided (Rick, 10/12): option (b), in v1.** A per-run tick box: "Include these N marked-junk files from FamilyArchive".
- It is off by default and lists the exact files.
- At the move, each file is re-checked: it must still be marked junk and unchanged.
- The tick box resets after the run.
- It never unlocks copy trimming on FamilyArchive.

Junk from other drives also comes into Cleanup as a second row, "Junk you marked". It uses the same engine and the same outcome report. Junk has no survivor proof; the proof is that Rick marked it and it hasn't changed since.

## Build order (once Rick says go)

1. Merge #143 (one engine). It needs Rick's go on the codex pass first.
2. Add the Cleanup job and page on top of it.
3. QA, then the five-dimension tests.
4. A dry run on the real catalog: the numbers, with no moves.
5. Rick runs it.

Events moves to its own design talk (`docs/Auto_Discover_Events_in_Media.md`), separate from this.
