# People profiles: folders keyed by UUID, display name = first alias

Status: design for `feature/people-uuid-folders` (2026-09-12 overnight theme).
Companion to `people_photo_rename_fix_2026_09_12.md`, which preserved photos
across a rename but left the store keyed by the short name.

## The ruling (Rick, 2026-09-12)

> A UUID is necessary. The name fields in the People tab are the link to the
> family tree — a person's full name matches their birth certificate. The
> aliases are what people use all the time: Rick, Dicky. The nickname should
> be what displays in the People tab: Rick, Dad, Ma, Dan. The first alias
> listed is usually the nickname most people use in the family.

Why now: two Richards (Jr = Rick, Sr = Dad) collide on the given-name folder
`richard/`. Dad was restored at `POI/dad` (uuid
`FF6C5474-EBB4-4D32-A9EF-B2D38647A146`) but cannot be *named* Richard until the
folder stops being keyed by the name.

## Layout after this change

```
~/Library/Application Support/VideoScan/
├── POI/
│   ├── .uuid-migration.json                    ← audit: what moved, when, backup path
│   ├── 2E6B1D2C-9F8A-4C61-8B7A-0C1D3E4F5A6B/   ← one folder per profile, uppercase uuid
│   │   ├── profile.json                        ← uuid, name fields, aliases, legacyFolderName
│   │   └── *.jpg / *.heic …                    ← reference photos, unchanged bytes
│   └── FF6C5474-EBB4-4D32-A9EF-B2D38647A146/
└── POI-backup-20260913-021500/                 ← APFS clone taken BEFORE any rename
```

* `POIStorage.folder(for: profile)` / `folder(forUUID:)` resolve to
  `POI/<UUID>/`. `POIStorage.legacyFolder(forName:)` is the ONLY name-keyed
  resolver left and is documented as migration/compatibility-only.
* `POIProfile.id` is now `uuid.uuidString`. Every in-memory dictionary,
  `ForEach`, drag id, save-flash id, portrait cache and tree-link badge that
  keyed on `id` therefore keys on the uuid. Kinship anchors already did.
* A rename is a `profile.json` write. `saveRenaming(from:)` survives as a thin
  wrapper over `save()` so call sites compile; it never moves a folder.
* `POIProfileFileStore.save` keeps its identity check: the destination folder
  must carry the same uuid or be absent. Two Richards are two uuids, two
  folders, no collision.

## What is keyed by uuid vs name after this change

| Concern | Key |
|---|---|
| Storage folder, `profile.json` location | uuid |
| `POIProfile.id`, `ForEach`, selection, drag/drop, save flash, tree badges | uuid |
| Kinship anchors (`.profile(id:)`) | uuid (unchanged) |
| Person Finder job descriptor `profileFolderName` | uuid string (legacy sanitized names still restore) |
| Trash folder name on delete | `POI-<sanitized display name>-<UTC>` (human readable; the uuid is inside `profile.json`) |
| Hallie matching (`PersonResolver`, `PersonNameClaim`) | canonical name + aliases + full-name forms — **unchanged** |
| People tab card label, context menus, job titles | `displayName` |
| Accessibility identifiers (`pf.person.<name>`) | canonical name — unchanged so the Gauntlet UI tests keep working |

## Display rule

`POIProfile.displayName` = the first alias that is not blank after trimming,
else `name`. Display only: the card, the delete/edit/search menu items, the
Person Finder job title and picker. Matching, exact-name resolution, logs,
accessibility ids and file names keep using `name`. The People tab sorts by
`sortOrder` (manual drag order) and then by `displayName`.

## Migration (`POIStorage.migrateToUUIDFoldersIfNeeded`)

Runs from `POIProfile.listAll()` / `POIStorage.allPOIFolders()` before any
enumeration, on the caller's actor, serialized by a lock. Cheap when there is
nothing to do: one directory listing, and a folder whose name is already its
uuid is not a candidate.

1. **Refuse** the real store under a test host (`POIProfileFileStore.guardRoot`)
   and on a remote viewer (`ViewerWriteGuard`). Nothing is read past the
   listing.
2. **Classify** every non-uuid-named folder first, reading nothing but
   `profile.json`: symlink → skip; no `profile.json` → skip; unreadable JSON →
   skip (left in place, never deleted); uuid absent → mint one and write it
   into the OLD location before any rename; the same uuid in two folders →
   skip both, log both paths, mark the run incomplete; a uuid folder already
   at the destination → skip, incomplete.
3. **Backup first**, only when at least one folder will actually move:
   `clonefile(2)` of the whole `POI/` directory to
   `VideoScan/POI-backup-<yyyyMMdd-HHmmss>/` (APFS: metadata-only, seconds for
   thousands of photos), falling back to `FileManager.copyItem` on a
   non-cloning volume. The method and the elapsed time are logged.
4. **Rename** each candidate with `renamex_np(RENAME_EXCL)` — atomic, same
   volume, fails rather than merges if the destination appeared meanwhile.
   Then rewrite `referencePath` and record `legacyFolderName` in the moved
   `profile.json` (dictionary-level write so keys a newer build wrote survive).
5. **Record** `POI/.uuid-migration.json` after every rename and at the end:
   `{startedAt, finishedAt, mapping: {old: new}, skipped: [{folder, reason,
   detail}], backupPath, backupMethod, complete, elapsedSeconds}`. A later run
   merges its mapping into the existing file.
6. **Log** one line per folder and one summary — `People migration: N folders
   → UUID, M skipped, backup at …, took X s` — to `appLog` (videoscan.log) and,
   drained by `DashboardState` once it has opened `catalog.log`, to
   `catalog.log`. Subsystem `Rick-Breen.VideoScan` for the os_log copy.

Idempotent: a second run finds no candidates and returns `.notNeeded`.
Nothing is ever deleted: skipped folders stay where they are and keep being
listed by name until Rick resolves them.

## Rollback (`POIStorage.rollbackUUIDMigration`)

Reads the mapping file, renames each `new → old` back (again `RENAME_EXCL`,
so a re-created legacy folder is never clobbered), restores `referencePath`,
and moves the mapping file aside as `.uuid-migration-rolledback-<stamp>.json`.
Test-only entry point; there is no menu item. The backup clone is the
belt-and-braces copy and is never touched by rollback.

## Consumers touched

* `PersonEditSheet` — photo imports go to `folder(for: originalProfile)` (a
  new person's fresh uuid is stable for the life of the sheet), never to a
  folder named after what has been typed so far.
* `IdentifyFamilyModel` — promotion creates/merges by uuid folder; an existing
  person is matched by canonical name, and an ambiguous name is skipped.
* `BundleImporter` — the bundle's `people/<x>/profile.json` uuid decides the
  local folder; a legacy bundle without uuids matches a local profile by name
  or mints one; a legacy-named local folder is still recognised as the local
  copy and installed over in place (the next launch migrates it).
* `BundleExporter`, `CatalogSync .tree("POI")` — copy whatever folders exist;
  viewers receive the uuid layout. Note: tree sync skips hidden files, so
  `.uuid-migration.json` stays on the master (recorded as a known gap).
* `PersonFinderModel` — delete/undo by uuid (`LastDeletedPOI` carries it),
  job refresh by uuid, `settings.referencePath` healed to the profile's folder
  when the stored path no longer exists.
* `GauntletSeams` — installs the seam POI into its uuid folder.
* `ArchivistProfileGallery` / `ArchivistBiographyPhoto` — already read
  `referencePath`, which `listAll` heals to the folder the JSON lives in.

## Tests (five dimensions)

* Logic — folder naming, `displayName` (blank alias skipped), rename is a JSON
  write, `id == uuid`.
* Migration fixture — 12 folders: six ordinary (unicode names included), one
  without uuid, one malformed, one symlink, one duplicate-uuid pair, one
  already uuid-named; mapping file, byte-identical backup, skip reasons,
  idempotent second run, rollback.
* Scale — 100 profiles × 1,000 files; the rename phase is O(profiles) and
  must finish well under a second, the backup clone is measured and logged.
* Isolation — a live-shaped root under the test host is refused before any
  I/O; every test works in its own temp root.
* Sensors — `migrationNeverDeletesAFolder`,
  `twoProfilesWithTheSameGivenNameCoexist`, `renameNeverMovesPhotos`,
  `displayNameIsTheFirstAlias`.
