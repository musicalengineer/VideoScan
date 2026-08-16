# Master Archive + Promote to Archive — design v2

**Status:** v2, 2026-08-15 late — supersedes the 8/14 strawman. Rick's
brief (8/15): "I'll choose a volume and you'll initialize it into our
system as the primary archive repo … then we'll promote some files."
Layout tailored from Rick's LoC-style research (numbered buckets, decade
ranges, date-prefixed filenames, manifest + naming guidelines).
Implementation begins overnight 8/15→8/16 for hands-on testing 8/16.

Related: `volume_taxonomy_proposal.md` (roles cleanup — bridge work, not a
prerequisite), `catalog_write_safety_design.md`, memory
`project_master_archive_promotion_design`.

---

## 1. Vocabulary (one word each — nag-button rule)

| Word | Meaning |
|---|---|
| **Master Archive** | The one volume/folder designated to hold the archive tree. Exactly one per catalog. |
| **Initialize** | Designate a volume as Master Archive AND scaffold the tree + index files. One gesture. |
| **Promote** | Verified copy of a record's file into the Master Archive tree + linked catalog record. Never a move. |
| **Refile** | Move an already-promoted file to a better place in the tree (date learned later). Later phase. |
| **Safe Archive ✓** | Derived chip: role Archive + redundant media + trust ok + reachable (`archivalSuitability`). Not hand-set. |

## 2. Layout (v2, tailored LoC)

```
<MasterArchiveRoot>/Breen_Family_Archive/
├── 00_Index/
│   ├── Archive_Inventory_Manifest.csv      # app-written, append-only, sha256 column = fixity
│   └── README_Naming_and_Layout.txt        # rules in plain English (the no-app cousin test)
├── 10_Photos/                              # exists for loose scans; Apple Photos owns photos
├── 20_Audio/
│   └── 1970-1979/1975/1975-12-25_Christmas-GrandpaVoice.wav
└── 30_Video/
    ├── 1990-1999/
    │   ├── 1992/1992-07-15_Summer-Vacation_01.mov       # year known → year folder
    │   └── 1994-xx-xx_Rick-Guitar.mov                   # decade known, year not → decade root
    └── Undated/                                         # nothing known
```

Rules
- Bucket by media kind from `streamType`/kind: video+audio & video-only → `30_Video`; audio-only → `20_Audio`; still images (if ever) → `10_Photos`. Numbered with gaps (40_Documents later).
- Decade folder `YYYY-YYYY` (unambiguous, sorts). Year folder only when the year is known. `Undated/` per bucket.
- Filename `YYYY-MM-DD_Slug[_NN].ext`; unknown month/day → `xx`; slug = curated title if set, else cleaned original stem; `_NN` only on collision within the folder; original extension preserved (**no transcode at promotion — the archive stores the verified original**). Original filename + path always recorded (manifest + `originalFullPath`).
- Date source: `inferredRecordDate` + confidence ≥ 0.6, else user-confirmed date if a field exists, else the file's best-known date is treated as unknown → decade-only if `inferredDecade`, else Undated. Promotion **warns**, never blocks, on Undated/low-confidence.
- Folders are created lazily on first use; Initialize creates only `Breen_Family_Archive/`, `00_Index/` (+ both files), and the three empty buckets.
- Manifest CSV columns: `promoted_at, archive_relpath, sha256, size_bytes, original_path, original_volume, record_id, source_record_id, record_date, date_confidence, people, star_rating`. Header row written by Initialize. Append = O_APPEND single write per row (same lesson as the write journal).

## 3. Catalog model (additive only)

- Catalog-level: `masterArchiveTargetID: UUID?` (the CatalogScanTarget) + `masterArchiveRootPath: String` (the `Breen_Family_Archive` folder). Persisted with the catalog (snapshot header extension, additive key). Single owner: setting a new master requires explicit "Change master archive" (later); v1 = set once, clearable.
- The designated target gets `role = .archive` (or `.lta` if user says so) and is a normal scan target so the archive tree is cataloged like any volume.
- Promoted copy = **new `VideoRecord`** at the archive path: `derivedFrom = source.id`, `derivationKind = .archivePromotion` (new enum case, additive), `contentHash` = sha256, `starRating = max(source, 3)`, people/dates/notes copied, `archiveStage = .masterAssigned`, `lifecycleStage = .archived`.
- Source record: `archiveStage = .masterAssigned`, journey event `.promote` ("Promoted to Master Archive as …"). Source stays live — deletion is a separate human decision.
- Query helper: `model.masterArchiveCopy(of: record) -> VideoRecord?` (via derivedFrom + kind) and the reverse. Cached by revision like other memos.

## 4. UI

- **Volumes window** → right-click volume → **Initialize as Master Archive…** Sheet: shows the volume, Safe Archive assessment (RAID? trust? reachable?), the folder tree it will create, an "Also add as scan target" line (always on for a never-seen volume), and a Confirm button. Also reachable via File ▸ Archive ▸ Initialize Master Archive… with an open-panel for a never-seen volume.
- Volumes window chip: **Master Archive** badge on the designated volume; **Safe Archive ✓** derived chip.
- **Catalog table** right-click (single/multi) → **Promote to Archive**. No master → alert: *"You need to designate a volume as the master archive."* with button **Initialize Master Archive…** (performs the fix). With master → confirmation sheet listing N files, total GB, destination folders (grouped), warnings (undated: n, low-confidence: n, already promoted: n — skipped), free space check. Confirm → one MFO **Promote** job.
- **Inspector**: "Master copy ✓ · Reveal" on sources; "Promoted from … · Reveal source" on archive copies. Show menu: **Not Yet Archived** / **Has Master Copy** filters.
- Menu bar: File ▸ Archive ▸ {Initialize Master Archive…, Promote Selected to Archive, Reveal Master Archive in Finder, Open Manifest}.

## 5. Promote job mechanics (MFO kind `.promote`)

Per file, disk-paced through the existing MediaVolumeGate:
1. Resolve destination relpath (§2). Refuse if the source IS already inside the archive root, or if a copy for this source already exists (idempotent).
2. Free-space check up front for the batch.
3. Copy to `dest.partial` → **full-file sha256 of source and of dest** (streamed) → mismatch = delete partial, mark failed, journal.
4. `rename(dest.partial → dest)`; F_FULLFSYNC file + dir.
5. Append manifest row (O_APPEND).
6. Main actor: create linked record, stamp source, `noteCatalogRecordsMutated()`, debounced save.
7. Job console line per file; summary sheet at end (promoted / skipped / failed with reasons).
Cancel-safe: partial files are removed on cancel; completed files stay (they're verified and recorded).

## 6. Tests (five dimensions)
- Logic: relpath resolution matrix (full date, year-only, decade-only, undated; slug cleaning; collision `_NN`; audio→20, video→30); manifest row escaping (commas/quotes in titles); Initialize idempotent; refuse-without-master alert path; idempotent promote.
- Scale: 100k-record `masterArchiveCopy(of:)` lookups within budget.
- Media matrix: promote one each of mp4/mov/mkv/mxf/avi synthetic fixtures; hashes verified.
- Isolation: Initialize into a temp dir never touches real App Support; test host never writes catalog.
- Sensor: a synthetic tree promoted twice yields exactly one copy + one manifest row per source; sha256 in manifest matches file.

## 7. Phasing
- **A (tonight):** model fields + Initialize (designation, scaffold, README, manifest header) + Volumes UI + File ▸ Archive menu.
- **B (tonight):** relpath resolver + Promote MFO job + right-click + confirmation sheet + linked records + inspector line + Show filters.
- **C (later):** Refile on date learned; cloud leg (`.backedUp` via rclone/B2 verify); taxonomy cleanup (`.retired` → badge); Collections/event subfolders; Media Patrol fixity re-hash of the archive.

## 8. Decisions taken (Rick may override)
- Promote implies ★★★ (one-way). Copy, not move. Warn-not-block on undated. Filenames date-prefixed. `Undated/` per bucket. Manifest = CSV (human) — no JSONL twin unless CSV appends prove fragile.
