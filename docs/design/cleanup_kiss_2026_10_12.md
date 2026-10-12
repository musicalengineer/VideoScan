# Cleanup, from scratch (KISS) — draft for the 10/12 morning talk

**Status:** draft for discussion. No code yet.
**Premise (Rick 10/11):** go back to basics. Every catalog file gets a stored full SHA-256 first, from the overnight Fill In Full Hashes job. A file without one is never deleted. Cleanup only centralizes logic we already have.

## The one question

Triage ▸ Cleanup answers: **"Which files are extra, and can go to the Trash?"**

Only files that are *extra* appear in it. A file is extra when either:

- an identical copy stays on another file, or
- you marked it junk.

Only copies, unsure files, and A/V pair halves are not extra, so they are not in Cleanup at all. They belong to Triage's other workflows or to the Catalog.

## One table, three rows

| | Files | GB | |
|---|---|---|---|
| ☑ **Copies**: an identical copy stays (full SHA-256 match, both stored) | n | GB | See files… |
| ☑ **Junk you marked** | n | GB | See files… |
| **Not checked yet**: looks like a copy, but no full hash yet | n | GB | Fill In Full Hashes… |

Under the table there is one button: **Move N files (X GB) to the Trash.**

That's the whole page. There are no grades, no "unsure" row and no only-copy row. "See files…" opens a plain list with the same filters as the Catalog. Unticking a file there leaves it out of this run.

## Rules (all existing; nothing new is invented)

- **Which copy stays:** the existing keeper rule. FamilyArchive first, then RAID › HDD › SSD, with the LaCie master preferred. An offline drive's copy is never chosen as the one that stays.
- **FamilyArchive is never trimmed as a copy.** Your marked junk is the only exception (see question 2).
- **Where files go:** everything goes through the one Trash engine (#143) to the Finder Trash. Every row gets the "In the Trash" marker. Nothing is permanently deleted, and the Trash is never emptied.
- **At the moment of the move:** the copy that stays must be on a connected drive, its full hash must be stored, and its size, date and inode must be unchanged since it was hashed. The extra file passes the same check. If anything differs, the file is skipped and named.

## What this removes from today's code

- The footer "hidden" caption, Show Again, and the review sheet.
- The Storage card, Steward, and Copies & Advice delete doors. They become links to Cleanup.
- CheckCopies' "unsure" machinery. The full hash makes a file either a copy or not.

## Numbers today (dry run on 10/11, sampled hashes; tonight's job turns them into proofs)

- Copies: 867 files, 629 GB, none of them on FamilyArchive.
- Junk you marked: 21 files, 0.65 GB. 20 of them are on FamilyArchive.
- Left out:
  - "tie for which copy to keep": 642 files, 587 GB, mostly copies *inside* FamilyArchive (about 254 GB).
  - A/V pair halves: 996 files, 309 GB.
  - Avid MediaFiles MXF: 420 of the copies (58 GB) would need their bins relinked.

## Questions for the morning, one at a time

1. **What does "prove it" mean at delete time?** Is a stored full hash plus an unchanged size, date and inode enough (instant)? Or should the job re-read the copy that stays (tonight's script read 1.25 TB, about 1–1.5 h)? I recommend the stored hash plus the unchanged check, with a re-read only when anything differs.
2. **FamilyArchive junk.** Should Cleanup show a one-line "Unlock FamilyArchive for this run" tick box, unticked by default, or never touch FamilyArchive?
3. **Copies inside FamilyArchive** (about 254 GB). Leave them for now, or give them their own later pass?
4. **Avid MediaFiles copies.** Include them, or leave them out?

## Events (for the same talk)

The tab charter's Events page groups recordings of the same occasion (Compare Footage lives there). `docs/Auto_Discover_Events_in_Media.md` is the research track behind it: a SigLIP 2 scene-search experiment on the M5 with 50–100 clips, first, then grouping. My proposal: build the Events page on the evidence we already have (dates, folders, and copies or edits of the same footage), and let the experiment feed suggestions into it later. The page doesn't wait on the models.
