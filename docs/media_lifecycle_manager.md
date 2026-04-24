# Media Lifecycle Manager

**Status:** Design proposal
**Last updated:** 2026-04-23
**Author:** Rick + Claude
**TL;DR:** A new top-level window (menu item: **Window > Media Lifecycle**) that shows every cataloged file through the lens of "what needs to happen next." Two modes: **Keeper Pipeline** (advance important media toward archive) and **Junk Review** (identify and clear worthless files). Green checkmarks track progress per file. When every file has all checkmarks or is confirmed junk, the volume is clean.

## The Core Idea

The Media tab shows files organized by volume and metadata. The People tab finds faces. Neither one answers the question Rick actually needs answered every day:

> "How much of this mess have I dealt with, and what's left?"

The Media Lifecycle Manager is that answer. It's a scorecard. Every file is either progressing toward archive or progressing toward deletion. When there's nothing left in the middle, the volume is done.

## Access

**Menu bar:** Window > Media Lifecycle (Cmd+L)

Opens a dedicated resizable window (same pattern as Settings — `Window` scene, not a tab). Can be open alongside the main app. Reads from the same catalog data; no separate scan needed.

Requires at least one completed catalog scan to have data to work with.

## Layout

```
┌─────────────────────────────────────────────────────────────────────┐
│  Media Lifecycle                                        [Volume ▾] │
├────────────────┬────────────────────────────────────────────────────┤
│                │                                                    │
│  KEEPER        │  ┌─────────────────────────────────────────────┐  │
│  PIPELINE      │  │ IMG  vacation_2003.dv                       │  │
│                │  │      720x480 DV  ·  14:23  ·  2.1 GB        │  │
│  ○ Unreviewed  │  │      Donna, Tim detected                    │  │
│    (847)       │  │                                              │  │
│  ◐ Has Family  │  │      ✓ Healthy   ✓ Master   ○ Backed Up     │  │
│    (38)        │  │      ○ Ready     ○ Archived                  │  │
│  ◐ Master Set  │  │                                              │  │
│    (23)        │  │      [Mark Master] [Verify Backup] [Skip]    │  │
│  ◐ Backed Up   │  ├─────────────────────────────────────────────┤  │
│    (15)        │  │ IMG  christmas_1998.mov                      │  │
│  ◐ Ready       │  │      1440x1080 MPEG2  ·  8:47  ·  1.4 GB   │  │
│    (8)         │  │      Donna detected                          │  │
│  ✓ Archived    │  │                                              │  │
│    (3)         │  │      ✓ Healthy   ○ Master   ○ Backed Up     │  │
│                │  │      ○ Ready     ○ Archived                  │  │
│ ─────────────  │  │                                              │  │
│                │  │      [Mark Master] [Find Copies]             │  │
│  JUNK          │  ├─────────────────────────────────────────────┤  │
│  REVIEW        │  │  ...                                         │  │
│                │  │                                              │  │
│  ⚠ Suspected   │  └─────────────────────────────────────────────┘  │
│    (312)       │                                                    │
│  ✗ Confirmed   │  ────────────────────────────────────────────────  │
│    (89)        │  Volume: InternalRaid  ·  847 unreviewed  ·  38   │
│  🗑 Deleted     │  with family  ·  312 suspected junk  ·  3 done   │
│    (0)         │  Progress: ██░░░░░░░░ 12%                         │
│                │                                                    │
├────────────────┴────────────────────────────────────────────────────┤
│  [Select All Suspected Junk]  [Confirm Selected as Junk]  [Delete]│
└─────────────────────────────────────────────────────────────────────┘
```

## The Five Checkmarks (Keeper Pipeline)

Each important media file displays five status indicators. All green = done.

### ✓ Healthy

The file plays correctly and has the expected streams.

**Auto-checked when:**
- ffprobe succeeded with valid duration > 0
- Has at least one video stream (or is a known audio-only keeper)
- If it was a Combine output: both A and V tracks present and in sync
- Quick integrity check: first and last 1MB readable, file size matches expected bitrate × duration within 20%

**Fails when:**
- ffprobe failed or returned errors
- Duration is zero or wildly inconsistent with file size
- Truncated file (size << expected)
- Container reports streams that don't decode (codec mismatch)

**User action:** If health check fails, show what's wrong. Offer "Mark as damaged" (moves to junk) or "Keep anyway" (override).

### ✓ Master Assigned

This specific file (on this specific volume) is designated as THE master copy.

**Auto-suggested when:**
- It's the highest-quality copy among known duplicates (by resolution, bitrate, codec)
- It lives on a volume not marked for retirement
- It's the only copy (automatic master by default)

**User action:** Click "Mark Master." If duplicates exist, show them side-by-side so Rick can pick the best one. The non-masters become "extra copies" — useful for backup verification but not load-bearing.

### ✓ Backed Up

At least one verified copy exists on a different physical machine or cloud.

**Auto-checked when:**
- Compare & Rescue (or the duplicate detector) confirms a matching file exists on a volume whose host machine differs from the master's host
- Cloud backup integration reports the file exists (future)

**Fails when:**
- Master is the only known copy
- All copies are on the same machine (e.g., two Mac Pro internal drives — same box, not a real backup)

**User action:** "Find Copies" searches all scanned volumes. If none found, "Copy to..." offers to copy the master to a backup volume.

### ✓ Ready for Archive

The file is stable, verified, and Rick has confirmed it's worth preserving long-term.

**Auto-suggested when:**
- Healthy + Master + Backed Up are all green
- Format is archival-friendly (not a proprietary wrapper, or has been re-wrapped)
- Metadata is captured (in the catalog, ideally also as sidecar)

**User action:** Click "Mark Ready." This is a deliberate human decision — the app suggests, Rick confirms. Batch "Mark All Ready" for files that meet all criteria.

### ✓ Archived

Written to long-term archive media and verified.

**User action only.** The app can't know if Rick burned an M-DISC or uploaded to cold storage. He clicks "Mark Archived" and optionally notes where (which disc, which bucket). The app records the date and location.

Future: if we integrate with a specific archive tool or cloud API, this could be partially automated.

## Junk Review Mode

The left sidebar's Junk section shows files that are candidates for deletion.

### How Files Become "Suspected Junk"

Scored automatically from catalog metadata. Each heuristic adds evidence:

| Signal | Weight | Example |
|--------|--------|---------|
| ffprobe failed | +5 | Corrupted beyond reading |
| Zero duration / zero bytes | +5 | Empty file |
| No video stream, no audio stream | +5 | Container with no content |
| Exact duplicate (MD5) of a file already classified | +3 | Extra copy |
| Path contains Avid render patterns | +3 | `PHYSV01`, `Precompute`, sequence-named MXF |
| Path contains FCP scratch/render dirs | +3 | `Render Files/`, `.fcpbundle/` |
| No audio + atypical resolution + short | +3 | Screen recording |
| Face detection ran, zero family hits, full coverage | +2 | No family members found |
| Duration < 3 seconds | +1 | Micro-clip, likely artifact |
| Audio sample rate 8kHz mono | +2 | Voicemail / VoIP |
| File in system/hidden directory | +2 | `.Spotlight-V100`, `.fseventsd` |

**Threshold:** Score >= 5 → Suspected Junk. Score >= 8 → Strong Junk Candidate (highlighted).

### Junk Review UI

Each suspected junk file shows:
- Thumbnail (if extractable) or format icon
- Filename, path, size, duration
- **Why it's suspected:** list of triggered heuristics in plain English
  - "No family members detected (full scan)"
  - "Avid render file pattern"
  - "Zero duration"
- Action buttons: **[Confirm Junk]** **[Actually Keep]** **[Preview]**

**Batch operations:**
- "Select All in Category" (e.g., all zero-duration files)
- "Confirm Selected as Junk"
- "Delete Confirmed Junk" — with a summary dialog:
  ```
  Delete 89 files (12.4 GB) from InternalRaid?

  Breakdown:
    34 × zero duration / corrupted
    28 × Avid render files
    15 × exact duplicates (master exists elsewhere)
    12 × no family detected

  ⚠ This cannot be undone for network volumes.
  Local volumes will use Trash.

  [Cancel]  [Move to Trash]  [Delete Permanently]
  ```

### Safety Rails

- **Cannot delete a file that has ANY keeper checkmark.** If it's someone's master or backup, deletion is blocked with an explanation.
- **Cannot delete a file with a family face match** unless the user explicitly overrides ("I know this is a false positive").
- **Network volumes (SMB):** No Trash available. Deletion is permanent. Extra confirmation required.
- **Batch delete shows individual file count by reason.** No "delete 500 files" without seeing the breakdown.

## Per-Volume Progress

The bottom status bar shows overall progress for the selected volume:

```
Volume: InternalRaid  ·  1,247 files  ·  Progress: ██████░░░░ 58%

  ✓ 312 archived or ready    ◐ 38 in pipeline    ○ 847 unreviewed
  ✗ 89 confirmed junk (12.4 GB reclaimable)
  ⚠ 312 suspected junk (pending review)
```

**"Progress"** = (archived + ready + confirmed junk + deleted) / total files. When this hits 100%, the volume is fully triaged.

The goal for each old Mac Pro volume: get to 100% and confirm the answer to "is there anything on this drive I still need?" is no.

## Data Model Additions

On `VideoRecord` (or a linked disposition record):

```swift
enum MediaDisposition: String, Codable {
    case unreviewed
    case important          // has family or manually marked
    case suspectedJunk
    case confirmedJunk
    case deleted
}

enum ArchiveStage: String, Codable {
    case none
    case masterAssigned
    case backedUp
    case readyForArchive
    case archived
}

// New fields on VideoRecord or a parallel store
var disposition: MediaDisposition = .unreviewed
var archiveStage: ArchiveStage = .none
var masterVolume: String? = nil         // which volume holds the master
var backupLocations: [String] = []      // volume names with verified copies
var archiveLocation: String? = nil      // "M-DISC #3" or "S3 glacier bucket"
var archiveDate: Date? = nil
var healthCheckPassed: Bool? = nil      // nil = not yet checked
var junkScore: Int = 0                  // sum of heuristic weights
var junkReasons: [String] = []          // human-readable explanations
var reviewedByUser: Bool = false        // user has looked at this file
```

Persisted via CatalogStore alongside existing fields.

## What This Does NOT Do

- **Auto-delete anything.** Every deletion requires explicit user confirmation.
- **Replace the Media tab.** The Media tab is for scanning and browsing. This window is for triage and lifecycle tracking.
- **Replace Compare & Rescue.** C&R does the cross-volume comparison. This window consumes those results to update backup status.
- **Manage the physical archive process.** Writing M-DISCs, uploading to cloud — that's outside the app. The app tracks that it happened.

## Implementation Phases

### Phase 1: The Window + Junk Scoring (MVP)

- New `Window` scene, menu item, Cmd+L
- Left sidebar with category counts (read-only from catalog data)
- Junk scoring engine — runs over catalog, populates `junkScore` and `junkReasons`
- Junk review list with per-file reasons and Confirm/Keep buttons
- Batch confirm + delete with safety dialog
- No keeper pipeline yet — just "Unreviewed" and "Junk" categories

This alone lets Rick start clearing junk immediately.

### Phase 2: Health Check + Family Flag

- Automated health verification (ffprobe integrity, size vs. duration, stream check)
- "Has Family" flag from face detection results (if PersonFinder has been run)
- Files with family matches auto-promote to "Important"
- Health checkmark appears on every file

### Phase 3: Master + Backup Tracking

- "Mark Master" action per file
- Integration with duplicate detector to show all copies
- Integration with Compare & Rescue results to verify backup status
- Backup checkmark based on cross-machine copy verification

### Phase 4: Archive Tracking

- "Mark Ready" and "Mark Archived" actions
- Archive location notes
- Per-volume progress bar
- "Is this volume clean?" query

## Connection to Existing Features

- **Catalog scan** provides the file inventory and metadata
- **PersonFinder** provides the "has family" signal
- **DuplicateDetector** identifies copies across volumes
- **Compare & Rescue** verifies cross-machine backup status
- **CombineEngine** resolves orphaned A/V pairs before lifecycle tracking
- **Junk scoring** reuses heuristics from `catalog-aided-face-detection.md` and `issue-08`

All inputs already exist or are planned. This window is the **integration point** that turns raw data into actionable status.
