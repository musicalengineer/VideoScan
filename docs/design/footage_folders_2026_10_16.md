# Footage folders — the Catalog shows events and copies the way the Finder shows folders (Rick, 2026-10-16)

## 1. In Rick's words

> "I observe some footage, I play it and inspect it and date it and rename it, then decide to
> upgrade the codec then promote to archive. This has to be as simple as possible. … when it
> gets promoted … I want, optional to archive the original or even delete the original and
> delete other copies. We have built all the logic elsewhere, we just need the workflow to be
> natural." — "I'd like to deal with an event, say a birthday, by seeing all the material
> together so I can dispose/dispense/promote/organize etc, all in one folder." — "we can turn
> this folder view off … Show: Events & Copies as Folders … we try it out for a while. … More
> important is how you relate media into folders — there's the challenge."

Mock (three modes; Rick chose C): https://claude.ai/artifact/5hKKk3tuQUn4Mh2zt9Gfxg

## 2. Ruling

- **A Show option, off by default for now:** Show ▸ **Events & Copies as Folders**. Off = the
  linear table exactly as today. On = the folder view below. Remembered per user.
- **An event is a folder** (Finder list view): a titled row with a chevron and its own summary
  columns — files · copies · total running time · how many archived · the date. Twist (or →/←)
  to see the members. Loose files (no confirmed event) sit at the same level as the folders,
  sorted together by the table's sort, like loose files in a Finder window.
- **A family is not a folder, it is the file.** Inside a folder every member is a row with its
  REAL name, volume and size (never a Finder-style "(1)" suffix — the app never invents a
  name). Members are ordered by family: the recording first, then its relatives under it,
  each with one glyph and muted words after the name:
  - `↳` made from it · FFV1 preservation master, verified (lineage: `derivedFrom`)
  - `=` copy · byte for byte, SanDiskWorkspace (same whole-file digest + size, or the
    duplicate group) — the row reads in grey
  - `⊂` clip of it · 04:12 to 07:17, by sound (a stored sound relation; phase 2)
  - `≈` same event · different footage (a member with no closer relation)
  The recording that carries the family is the archived file if one exists, else the best
  transfer by `RelatedLadder.betterTransfer`'s order, else the longest. A legend line under
  the table names the four glyphs while the option is on.
- **A new derivative lands under its source.** When Transcode / Reformat / Trim / Repair
  finishes, the folder expands, the new row appears under the source with `↳`, and it is
  selected. A failed job adds nothing (as today).
- **Double-click a folder** scopes the list to that event with a breadcrumb "‹ All ·
  Thanksgiving 2009"; Esc or the crumb returns. The right-click item **Show Copies & Related…**
  stays for a file with NO event (the family alone, scoped); for a file in a folder it reads
  **Show in its event** and opens the folder.
- **Keyboard:** ↑↓ walk the visible rows (members included when open); →/← open/close the
  selected folder; Esc clears the scope. Sorting applies to folders-and-loose-files at the top
  level and to members within a folder (family order wins inside a folder).
- **Calm by default:** copies grey, relation words muted, the keeper's existing tag (Ready /
  Archived) is the only colour.

## 3. How media is related into folders — the challenge

Four sources, all already in the catalog; the view is a join, not a new analyzer:
1. **Events** — `ConfirmedEvent` members (EventsDecisionStore / `events_latest.json`). Only
   CONFIRMED events become folders; suggestions stay in Triage ▸ Events until Rick confirms.
   Folders fill as the Events rules improve — that is the point of the view.
2. **Copies** — same stored whole-file SHA-256 + size (`storedFullDigest`), else the duplicate
   group (`duplicateGroupID`); a sampled `v1:` hash never makes a copy.
3. **Lineage** — `derivedFrom` + `derivationKind` (transcode, reformat, trim, repair, promote).
4. **Sound** (phase 2) — within an event the members are few, so a pairwise audio match across
   the folder's members (the sidecar prints, `AudioFingerprintMatcher`) is cheap; its verdicts
   (clip of / same recording / overlap) are cached per event in a small sidecar and shown as
   `⊂`. Not in this cut.

A file can belong to one confirmed event (Events v1 guarantees non-overlap of confirmed
ranges); a copy outside any event follows its original into the folder (it is the same
content), shown grey with its own volume.

## 4. The model — pure, off the main actor

`FootageFolders` (app target, value types): inputs = `[FootageFolders.Row]` (id, name, path,
volume, digest, size, duration, derivedFrom, derivationKind, duplicateGroupID, isArchived,
isArchiveFile, dates…) + `[ConfirmedEvent]` → output = `FootageFolders.Display` = a FLAT
array of display rows `{ kind: folder(eventID) | loose(recordID) | member(recordID, depth,
relation) , sortKey… }` plus per-folder summaries. The Catalog's existing `Table` renders
this flat array (an indented name cell + a chevron button for folders); no hierarchical
`Table`, no per-row work in a body. Built in the same place and cadence as the coverage
snapshot (one O(records) pass off-main per debounced catalog change, equality-gated
publish), with the set of open folders and the scope kept in `CatalogTableState`. 100k rows:
budget alongside the coverage pass.

## 5. Then the tail of the loop (after the view holds)

Promote… from a folder member builds the archive set; once proven, the folder offers the
three options Rick named (archive the original alongside · retire the original · remove the
other copies) through the Cleanup lanes already built, scoped to this family — never a new
deleter. Separate cut, safety-critical.

## 5a. Second cut — making and fixing folders by hand (Rick, 2026-10-16 evening)

> "as I am perusing media files I can right click → Add to <Event Folder> … the list of
> folders could get long … like Apple Photos, right-clicking several media files → Create New
> Event … <name>" — and, later, drag and drop onto a folder.

- **No submenus in the Catalog** (Rick 2026-09-22: a macOS submenu closes whenever the window
  updates, and the Catalog window updates many times a second). So the gestures are ONE item
  each, opening a small picker, never a nested menu of folders.
- **Right-click ▸ Add to Event…** (one or many files): a picker with a type-ahead search over
  event names and, under it, the nearest events first by the files' dates; pick → the files
  join that folder. **Right-click ▸ New Event from Selection…**: name prefilled from the date
  + category guess ("Thanksgiving 2009"), editable, confirm → a folder. **Right-click ▸ Remove
  from Event** on a member.
- **Hand decisions are decisions**: stored in the Events decisions sidecar beside confirm /
  dismiss (`EventsDecisionStore`); the Events rules never undo a hand decision (the ingest
  ruling: returning content inherits its verdict). A hand-made event is a folder like any
  other — the join in §4 does not change.
- **Drag and drop onto a folder row** = the same decision, a later gesture, after the view
  and the picker have been used for a while.

## 6. Tests (five dimensions)

Logic: grouping by event / copies / lineage / loose; keeper choice; family order; a copy
outside an event follows its original; a `v1:` hash is never a copy. Scale: 100k rows with
2k events inside the coverage budget. Media: none (no media is opened). Isolation: a damaged
events file → no folders, never a crash. Sensor: no view body touches `records`; the folder
rows observe only the published display.
