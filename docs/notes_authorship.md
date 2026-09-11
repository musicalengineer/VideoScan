# Notes authorship (GH #176)

Rick's ruling, 2026-09-11: *"author of notes was not clear. Now it will be
clear: ffmpeg said, Rick said, user said, etc."*

## The two fields

| Field | Who writes it | What it holds |
|---|---|---|
| `VideoRecord.notes` | machines only | One line per event, **every line names its author** — either a signed prefix (`ffprobe: …`) or one of the legacy self-describing shapes (File Journey stamps `Promote 2026-09-09T17:20:11Z: …`, `Combined: …`, `MXF header parsed (…`). |
| `VideoRecord.userNotes` | people only | The Notes… sheet, the Archive Angel review-sheet note. Copied verbatim by clone / Promote / repair-confirm / rescan-preservation. |

Inspector: "Your Notes" shows `userNotes`; "Notes" shows `notes`. Plain
catalog search never reads `notes` (`note:` field prefix opts in).

## Author vocabulary (`MachineNote.Author`, VideoScanCore/MachineNote.swift)

| Prefix | Writer |
|---|---|
| `ffprobe:` | ScanEngine — ffprobe stderr captured by a probe (one signed line per stderr line) |
| `ffmpeg:` | MFO jobs (Transcode, Balance Audio, Cleanup, Reformat, Trim, Verify Audio) — today they still write their File Journey stamps, which read as `ffmpeg` |
| `scan:` | scan-engine diagnostics: timeouts, cancel, sniff reject, MXF fallback, `humanReadableDiagnosis`, document ingest; Reconcile/Migrate/Confirm stamps read as `scan` |
| `combine:` | Correlate/Combine (`Combined: …` legacy shape reads as `combine`) |
| `recipe:` | Find-and-Tag person recipe result (`FindPerson(Donna) recipe-v1-native …`) |
| `promote:` | Master Archive promotion stamps (`Promote <ISO>: …`) |
| `cleanup:` | duplicate-cleanup provenance (`copy at <path> … removed <date>; identical bytes`) |
| `angel:` | reserved for the Archive Angel (writes no machine text today) |

Writers: `MachineNote.line(author:text:)` → `"<author>: <text>"` (multi-line
text gets every line signed); `MachineNote.append(_:to:)` for the `"\n"`
join. Readers: `MachineNote.author(of:)` returns the author for **both** the
signed shape and every legacy unsigned shape (tables in the same file);
`MachineNote.signed(_:)` gives the storage form of a legacy line.

`UserNotesMigration.isMachineLine` and `ArchiveAngelCandidate.isMachineNoteLine`
both delegate to it — there is one classifier. A bare leading `[` is **not**
machine (`[1984] Dad and Donna at Thanksgiving` is Rick's, codex #1303); the
ffprobe header `[aac @ 0x7ac800a80]` is.

## How the pollution happened, and the repair

The 2026-07-23 notes→userNotes split ran lazily on every catalog load and knew
three machine shapes (`[`-lines, journey stamps, `Combined:`/`MXF header
parsed (`). Every other line a machine wrote to `notes` looked human and was
pumped into `userNotes` on the next load: ffprobe stderr that does not start
with `[` (`Unsupported codec with id …`, `Last message repeated N times`,
`Could not open codec …`, `Consider increasing the value …`), the scan
diagnosis text, the Find-and-Tag recipe line (861 lines), the cleanup
provenance line. Census 2026-09-11: 13,879 records, 9,988 with `userNotes`,
**9,979 all-machine, 9 with a line Rick typed** (22,462 lines).

`VideoScanModel.repairMachineTextInUserNotes()` (VideoScanModel+NotesRepair.swift)
runs once at catalog load, right after the legacy split and before the search
index is built:

1. Skips entirely for a test host on the shared store and for read-only
   viewer mode.
2. Marker `notes-repair.v1.done` beside `catalog.json` — the persisted
   "already ran" flag. It travels with the catalog (no UserDefaults).
3. Plans per record with `NotesRepair.apply(notes:userNotes:)`: machine lines
   leave `userNotes` and are appended to `notes` **signed** (`ffprobe:
   Unsupported codec …`; already-present lines are not duplicated); human
   lines stay in order.
4. Backup **before** mutating: `catalog.pre-notes-repair.<stamp>.json` via
   the shared `snapshotCatalog(prefix:)` writer. No backup → nothing changes,
   no marker, retry next launch.
5. One log line: `notes repair: N records cleaned, M human notes kept, L
   machine lines moved back to notes, backup at …`.

Idempotent by construction as well as by marker: a second pass finds no
machine line in `userNotes`.

## Sensors

`VideoScanTests/NotesAuthorshipSensorTests.swift` scans the app and Core
sources:

* every `userNotes =` / `+=` / `.userNotes.append(` site must be in the
  allow-list of human entry points and verbatim field copies;
* every file assigning `.notes` must be registered (a new writer is the
  moment to sign its lines);
* the exact unsigned assignments this fix removed must not return.

`MachineNoteTests.swift` pins the recognition table (every legacy shape,
every signed shape, the nine live human lines); `NotesRepairMigrationTests.swift`
runs the repair on temp catalogs (mixed / all-machine / human-only / empty,
backup, marker, idempotence, read-only skip) and on a census-shaped 13,879
record set (9,979 cleaned, 9 kept).
