# Issue #8: Bad File Triage — Filter, Organize, and Delete Unrecoverable Files

## Problem

A large family media collection inevitably contains a significant fraction (estimated 40-50%) of files that are junk: corrupted, unplayable, zero-length, or duplicate training/test videos with no family members. Currently there's no efficient workflow to identify, review, and remove these files.

## Current State

VideoScan already detects several "bad file" categories during scanning:
- **ffprobe failed** — file can't be probed at all
- **No streams** — container exists but has no audio or video tracks
- **Not playable** — `isPlayable == "No"` (probed but won't play)
- **Zero duration** — `durationSeconds == 0`
- **Duplicate extra copies** — high-confidence duplicates (handled by issue #12)

These are all visible in the catalog table but there's no dedicated workflow for acting on them.

## Proposed Solution

### Phase 1: Triage Filter Mode (Quick Win)

Add a **"Show Triage Candidates"** toggle/filter to the catalog toolbar that restricts the table to files matching triage criteria:

```swift
enum TriageCategory: String, CaseIterable {
    case ffprobeFailed = "Probe Failed"
    case noStreams = "No Streams"
    case notPlayable = "Not Playable"
    case zeroDuration = "Zero Duration"
    case zeroSize = "Zero Bytes"
    case duplicateExtra = "Duplicate Extra Copy"
    case suspectedJunk = "Suspected Junk"  // filename heuristics
}
```

**UI:** A filter bar below the toolbar with checkboxes for each category + total counts. Selecting a category filters the table to show only those files.

**Filename heuristics for "Suspected Junk":**
- Files matching patterns like `test_*`, `sample_*`, `tmp_*`, `Untitled*`
- Files in directories named `Trash`, `temp`, `.Trash`, `Recovered`
- Extremely short files (< 1 second) that aren't photos

### Phase 2: Bulk Actions

Once filtered, the user needs actions:

1. **Delete Selected** — move to Trash (reversible) or permanent delete
   - Prefer `FileManager.trashItem(at:resultingItemURL:)` on local volumes
   - For network volumes (SMB), trash isn't available — use `removeItem` with confirmation
   - Show summary before executing: "Delete 47 files (3.2 GB) from MyVolume?"

2. **Move to Folder** — organize files into triage folders
   ```
   /Volumes/MyVolume/VideoScan_Triage/
   ├── by_decade/
   │   ├── 1980s/
   │   ├── 1990s/
   │   └── 2000s/
   ├── useful/
   ├── needs_work/
   └── rejected/
   ```
   - Decade inference from file metadata (creation date, embedded timecode, parent folder name)
   - "Useful" / "Needs Work" / "Rejected" are manual user classifications

3. **Mark as Keep** — explicitly mark a file as "reviewed, keep it" so it doesn't show up in triage again
   - Store in a `triageStatus` field on VideoRecord
   - Persist across sessions via CatalogStore

### Phase 3: Smart Junk Detection

Go beyond simple metadata checks:

1. **Thumbnail analysis** — extract a frame and check if it's solid black/color bars/test pattern
   ```swift
   // Extract middle frame, check if it's uniform
   let image = try await extractFrame(at: duration / 2)
   let isBlank = image.averageColorVariance < threshold
   ```

2. **Audio silence detection** — flag files that are pure silence
   ```bash
   ffmpeg -i file.mov -af silencedetect=noise=-50dB:d=0.5 -f null -
   ```

3. **No-face flag** — after running person finder, files where zero faces were detected across all frames are candidates for junk (if your goal is family video preservation)

### Phase 4: Dedicated Triage View (Optional)

If the filter approach feels cramped, add a third tab:

```
┌──────────────────────────────────────────────┐
│ [Video Catalog] [Person Finder] [Triage]     │
├──────────────────────────────────────────────┤
│ Category sidebar  │  File list  │  Preview   │
│ ○ Probe Failed(12)│  thumb.mov  │  [player]  │
│ ○ No Streams  (5) │  test2.avi  │            │
│ ○ Not Playable(8) │  clip3.mxf  │  [Delete]  │
│ ○ Zero Duration(3)│             │  [Move]    │
│ ○ Duplicates (47) │             │  [Keep]    │
│ ○ Susp. Junk (23) │             │            │
├──────────────────────────────────────────────┤
│ Status: 98 triage candidates, 12.4 GB        │
│ [Delete All Selected] [Move to Triage Folder]│
└──────────────────────────────────────────────┘
```

## Network Volume Considerations (SMB)

- `FileManager.trashItem` doesn't work on SMB — use `removeItem` with extra confirmation
- File moves within the same SMB share are fast (rename); cross-share moves are slow (copy+delete)
- Check write permissions before attempting operations: `FileManager.isWritableFile(atPath:)`
- Handle stale file handles gracefully — SMB connections can drop during long operations

## Data Model Changes

Add to `VideoRecord`:
```swift
var triageStatus: TriageStatus = .unreviewed  // .unreviewed, .keep, .junk, .needsWork
var triageCategory: TriageCategory?           // auto-populated during scan
```

Persist via CatalogStore alongside existing fields.

## Implementation Order

1. **Phase 1 (filter mode)** — 1-2 days, high value, builds on existing data
2. **Phase 2 (bulk delete/move)** — 1-2 days, the core workflow
3. **Phase 3 (smart detection)** — 2-3 days, nice-to-have
4. **Phase 4 (dedicated tab)** — 2-3 days, only if filter mode is insufficient

## Recommendation

Start with Phase 1 + Phase 2 — the filter + bulk delete covers the immediate need of clearing out obvious junk. Phase 3 and 4 can wait until the core pipeline is more stable.
