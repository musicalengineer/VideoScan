# Import / Export Strategy

How VideoScan moves data between machines (Mac Studio ↔ MacBook Pro)
and how it should handle conflicts, duplicates, and Apple Photos integration.

## Bundle Format (`.videoscanbundle`)

A single directory containing everything needed to replicate one Mac's
VideoScan state on another:

```
VideoScan_MacStudio_2026-04-27.videoscanbundle/
├── manifest.json      # version, host, counts, sizes
├── catalog.json       # all VideoRecord entries
├── volumes.json       # per-volume metadata (role, trust, tech, etc.)
├── settings.json      # machine-portable PersonFinder settings
└── people/
    ├── donna/
    │   ├── profile.json
    │   ├── apple_1234_0.heic
    │   └── apple_1234_1.jpeg
    └── timmy/
        ├── profile.json
        └── apple_5678_0.jpeg
```

Machine-specific fields (pythonPath, outputDir, recognitionScript) are
deliberately excluded from settings.json — they're re-derived on the
destination machine.

## Current Behavior (v1)

| Data        | Strategy         | Notes                                    |
|-------------|------------------|------------------------------------------|
| Catalog     | Merge by content identity | No duplicates; new records added   |
| Volumes     | Overwrite on path match   | New volumes added as offline       |
| Settings    | Overwrite portable fields | Machine-specific paths untouched   |
| People/POI  | **Overwrite by name**     | Same-named folder replaced entirely |

## Problem: Person Conflicts

If "Timmy" exists on both machines with different reference photos, the
current import silently replaces the local folder. This works when one
machine is authoritative, but loses local-only photos.

### Proposed: Three-Way Person Merge

When importing a person whose name already exists locally, show a dialog:

```
"Timmy" already exists on this Mac.

  Local:   8 reference photos, engine: Vision, threshold: 0.52
  Incoming: 12 reference photos, engine: ArcFace, threshold: 0.40

  ○ Merge photos (union of both sets, keep local settings)
  ○ Replace with incoming (overwrite everything)
  ○ Keep local (skip this person)
  ○ Keep both (rename incoming to "Timmy (MacStudio)")

  □ Apply to all remaining conflicts
```

**Merge logic for photos:**
- Deduplicate by file content hash (MD5 or SHA-256 of image data)
- Photos with different content but same filename: rename the incoming one
  with a suffix (e.g., `apple_1234_0_imported.heic`)
- Merge keeps the local profile.json settings (thresholds, engine, crop)
  unless the user picks "Replace"

**Merge logic for profile settings:**
- On "Merge": keep local thresholds, engine, crop, notes
- On "Replace": take incoming everything
- Aliases: always union (no harm in having more aliases)
- Rejected files: always union (prevents re-testing known-bad photos)

### Implementation Plan

1. Add content hashing to reference photos (MD5, computed lazily on import)
2. Add a `POIMergeStrategy` enum: `.merge`, `.replace`, `.keepLocal`, `.keepBoth`
3. Show conflict dialog per-person (with "apply to all" checkbox)
4. `BundleImporter.installPOIs()` takes the strategy as a parameter

## Reference Photos: Copies vs. Apple Photos References

### Current: Full Copies

Photos imported from Apple Photos via PhotosPicker are copied into
`~/Library/Application Support/VideoScan/POI/<name>/` as regular files.
This is simple, portable, and works offline.

**Pros:** Self-contained, works without Photos permission, survives iCloud
photo deletion, trivially bundled for export.

**Cons:** Duplicates storage. A 50-photo POI with HEIC originals is ~100 MB.
Multiply by 10 family members × 2 machines = ~2 GB of duplicated photos.

### Future Option: PHAsset References

Apple's PhotoKit provides `PHAsset.localIdentifier` — a stable ID that
survives iCloud sync across devices on the same Apple ID. We could store
the identifier alongside (or instead of) the photo copy.

```swift
struct PhotoReference: Codable {
    var localCopy: String?          // filename in POI folder (current behavior)
    var phAssetID: String?          // PHAsset.localIdentifier
    var phAssetFingerprint: String? // PHImageManager content hash for change detection
}
```

**Resolution order on launch:**
1. If `localCopy` exists on disk → use it (fast, offline-safe)
2. Else if `phAssetID` is set → fetch from Photos library, cache locally
3. Else → photo is missing, flag for user attention

**Pros:** No storage duplication. Photos stay in sync if user crops or
edits them in Apple Photos. Cross-device via iCloud Photo Library.

**Cons:**
- Requires Photos permission (entitlement + user grant)
- PHAsset IDs are only stable across devices on the **same Apple ID**
  (Rick's Mac Studio and MBP share an Apple ID, so this works for him)
- If the photo is deleted from Apple Photos, the reference breaks
  (mitigated by keeping localCopy as fallback)
- Bundle export still needs to include the actual image bytes for
  portability — you can't assume the destination has the same iCloud
  library

**Recommendation:** Keep copies as the primary storage. Optionally store
phAssetID as metadata for future "refresh from Photos" or "find updated
version" features. Don't depend on it for day-to-day operation.

## Apple Photos: "Who Is Timmy?"

Apple Photos has built-in face recognition that groups photos by person.
Users can name these groups. We could leverage this to bootstrap POI
reference photos automatically.

### How It Would Work

```swift
import Photos

// 1. Request Photos permission
PHPhotoLibrary.requestReadWriteAuthorization { status in ... }

// 2. Fetch all "People" albums (face groups the user has named)
let people = PHCollectionList.fetchTopLevelUserCollections(with: nil)
// Filter to type .smartAlbum with subtype .smartAlbumFaces

// 3. For a named person, fetch their photos
let fetchOptions = PHFetchOptions()
fetchOptions.predicate = NSPredicate(format: "localizedTitle == %@", "Timmy")
let albums = PHAssetCollection.fetchAssetCollections(
    with: .smartAlbum, subtype: .any, options: fetchOptions)
```

**The catch:** Apple's People album API is limited. You can enumerate
smart albums but there's no public API to directly query "photos of
person named X" by face cluster. The People album is a `PHAssetCollection`
with subtype `.smartAlbumFaces`, but accessing individual named people
requires fetching all face-group collections and matching by title.

### Practical Approach

Add an "Import from Apple Photos People" button in the Person Edit sheet:

1. Fetch all named People albums from Photos
2. Present a picker: "Select a person from your Photos library"
3. Show their Photos-identified face photos
4. Let user select which ones to use as reference photos
5. Copy selected photos into the POI folder (with phAssetID stored)

This gives us:
- **Bootstrap**: Create a new POI with 20+ reference photos in seconds
- **Refresh**: "Update from Photos" button to pull any new photos Apple
  has tagged for that person
- **Cross-age coverage**: Apple Photos often has photos spanning decades,
  which is exactly what face recognition across old home videos needs

### Privacy Note

Photos access requires:
- `NSPhotoLibraryReadWriteUsageDescription` in Info.plist (already have
  this for PhotosPicker)
- Full Photos permission for PHAsset enumeration (PhotosPicker only
  needs limited access — this is a step up)

## Catalog Merge Strategy

The catalog merge is already solid (content-identity dedup), but worth
documenting edge cases:

| Scenario | Behavior |
|----------|----------|
| Same file, same volume | Skipped (content identity match) |
| Same file, different volume | Both kept (different fullPath) |
| File updated since last export | Both kept (different MD5/size) |
| Paired A/V records | pairedWith re-linked by ID after import |
| Star ratings | Local rating preserved if record exists |
| Duplicate groups | Re-detected on next duplicate scan |

**Content identity key:** `filename + duration + totalSize` (current).
This is intentionally loose — two copies of the same file on different
volumes will have the same identity, but their fullPath differs so both
are kept. This is correct: we want to know about every copy.

## Volume Metadata Merge

| Scenario | Behavior |
|----------|----------|
| Path exists locally | Overwrite role/trust/tech/notes |
| Path doesn't exist | Add as offline volume |
| Local volume not in bundle | Left untouched |

This is one-directional: the bundle is authoritative for volumes it
contains. Local-only volumes are never deleted.

## Future Ideas

- **Incremental sync**: Track a `lastExportDate` per machine and only
  bundle records added/modified since then. Reduces bundle size for
  frequent syncs.
- **iCloud sync**: Store catalog.json + profiles in iCloud Drive
  container. Automatic, but conflict resolution becomes harder (no
  user-facing merge dialog).
- **AirDrop bundle**: Register `.videoscanbundle` as a document type
  so AirDropping it to another Mac opens VideoScan and starts import.
- **Delta bundles**: Export only changes since a given date, like a
  git patch. Useful for large catalogs where most records haven't changed.

## Summary

The guiding principle: **copies are king, references are metadata**.
Always have the actual bytes for reference photos and catalog records.
Use Apple Photos identifiers and iCloud as supplementary channels, not
primary storage. The bundle should be fully self-contained — importable
on a Mac with no network, no iCloud, and no Apple Photos.
