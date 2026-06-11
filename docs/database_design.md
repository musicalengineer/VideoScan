# VideoScan Database Design

**Status:** living document. Update when you change a write contract, add a
new file to the database surface, or change the backup bundle.

## TL;DR

VideoScan's "database" is **four JSON files plus one folder tree of photos**.
There is no SQLite for the catalog. The choice is deliberate: the catalog
fits in RAM, every change is human-debuggable in a text editor, and
restoring from backup is a `cp` away.

The expensive-to-compute part — the **dossier** (Qwen scene captions,
Whisper transcripts, OCR dates) — is durable across three layers:

1. **JSONL delta files** on Crucial2TB — the workers' write-ahead log.
2. **catalog.json** on Mac Studio — the merged, authoritative state.
3. **The bundle export** (Export Everything) — the user-triggered
   point-in-time snapshot, typically saved to iCloud Drive.

Any one of those three can be lost and the dossier survives.

---

## The five things that make up the database

| What | Where | Size | Who writes | Backup? |
|---|---|---|---|---|
| `catalog.json` | `~/Library/Application Support/VideoScan/` | ~49 MB | app (Mac Studio) AND merger | `.prev` + bundle |
| `catalog.json.prev` | same dir | ~36 MB | auto-rotated on each write | none (it IS the backup) |
| POI tree | `~/Library/Application Support/VideoScan/POI/` | ~191 MB | app (POIStorage) | bundle |
| Dossier JSONL deltas | `/Volumes/Crucial2TB/dossier-deltas/m{1,4,5}.jsonl` | ~25 MB total | dossier_batch.py workers | **none today** |
| `manifest.sha256` | `~/Library/Application Support/VideoScan/` | ~526 KB | app on save, merger on merge | regenerated; not backed up |

Out of scope for this doc (they're cache or volatile):

- `metadata_cache.sqlite` — ffprobe results cache; re-derivable from
  scanning the source media. Loss = a slow re-scan, not lost work.
- `/tmp/dossier-merger-offsets.json` — merger's "how far have I read"
  bookmark. Lost on reboot, harmless (re-replay is idempotent).
- `catalog.pre-relocate.*.json` — one-shot snapshots written by the
  Relocate-Volume tool before a destructive operation. Kept until the
  user prunes them.

---

## catalog.json — the authoritative state

**Path:** `~/Library/Application Support/VideoScan/catalog.json`

**Format:** single JSON object, `version 6`:

```json
{
  "version": 6,
  "savedAt": "2026-06-07T22:00:00Z",
  "savedFromHost": "Mac Studio",
  "records": [ {...VideoRecord...}, ... ]
}
```

Each record (see `Models.swift::VideoRecord`) holds:

- **Identity:** `fullPath` (primary key), `filename`, `partialMD5`
- **Technical:** size, codec, resolution, frame rate, duration, etc.
  — re-derivable from the file on disk
- **Dossier channels (expensive!):** `sceneCaptions`, `audioTranscript`,
  `ocrDateCandidates`, `ocrText`, `inferredRecordDate`,
  `inferredDateConfidence`, `dossierProcessedAt`, `dossierProcessedBy`
- **User-edit:** `detectedPeople`, `confirmedByUserPeople`,
  `mediaDisposition`, `lifecycleStage`, `starRating`, `notes`, etc.

**Primary key:** `fullPath`. The merger and the rescan-preservation pass
both match records by `fullPath` alone.

**Write contract:**

- **App writes** (`saveCatalogNow` / debounced auto-save in
  `VideoScanModel`): atomic rename through `catalog.json.tmp` →
  `catalog.json`. Rotates the previous file to `.prev`.
- **Merger writes** (`scripts/merge_dossier_jsonl.py::atomic_write_catalog`):
  same atomic rename pattern. Rotates `.prev`.
- **Single-writer-per-process discipline.** The merger and the app both
  write catalog.json, but they never run on the same machine at the same
  time in production — the merger only runs on Mac Studio (M4) where the
  app is open. We rely on the atomic rename, not on locking.

**Read contract:**

- Decoded once at app launch into the in-memory `records: [VideoRecord]`
  array. The in-memory copy is the working set; catalog.json is the
  persistent store. **A reboot doesn't lose work — the debounced
  auto-save flushes it within seconds.**

---

## POI tree — irreplaceable user-curated data

**Path:** `~/Library/Application Support/VideoScan/POI/<name>/`

**Contents:**

- `profile.json` — POIProfile (name, decade ranges, cover image ref)
- `*.jpg` / `*.heic` — reference photos (manually picked by Rick)
- Optionally `clusters/`, `faces/` — generated artefacts that CAN be
  re-derived, but slowly

**Why it matters:** the reference photos are Rick's curated selections
across years of family video. Many were extracted from one-frame hits
and would be tedious to re-find. Losing the POI tree means losing the
face-recognition tuning.

**Backup:** included in the bundle export. Conflict resolution on
import: the side with more reference photos wins (mtime tiebreak).

---

## Dossier JSONL deltas — the write-ahead log

**Path:** `/Volumes/Crucial2TB/dossier-deltas/m1.jsonl` (Mac mini), `m4.jsonl`
(Mac Studio), `m5.jsonl` (M5 MacBook Pro).

**Format:** one JSON object per line, append-only:

```json
{"fullPath": "/Volumes/X/clip.mov", "fields": {"sceneCaptions": [...], "dossierProcessedAt": "2026-06-05T22:00:00Z"}}
```

**Who writes:** `scripts/dossier_batch.py` running on each of the three
fleet nodes (M1 / M4 / M5). Append-only — workers never rewrite or
truncate.

**Who reads:** `scripts/merge_dossier_jsonl.py` running as a daemon on
Mac Studio, polling every 60 s. Tracks per-file read offsets in
`/tmp/dossier-merger-offsets.json` so it doesn't re-apply lines.

**Why it exists:** the dossier compute is the expensive part (hours
to days). If catalog.json were the only sink, a buggy write or a
disk failure could destroy weeks of work. The JSONLs are an
append-only durable log that can rebuild catalog.json from scratch.

**Idempotency:** applying the same delta twice is a no-op
(`apply_deltas` does `rec[k] = v`, not append). This is what makes
"delete the offsets file and replay everything" safe.

**Known weak link:** all three JSONLs live on **one disk** (the
Crucial2TB SSD on Mac Studio). If that disk dies and the catalog has
no dossier fields (or has been wiped), the compute is gone. Mitigation:
see [Backup coverage](#backup-coverage) below.

---

## manifest.sha256 — integrity verification

**Path:** `~/Library/Application Support/VideoScan/manifest.sha256`

**Format:** GNU shasum format, one line per file, sorted by relpath:

```
<sha256_hex>  catalog.json
<sha256_hex>  catalog.json.prev
<sha256_hex>  POI/donna/profile.json
<sha256_hex>  POI/donna/ref_001.jpg
...
```

**Who writes:** the Swift app's `CatalogSync.computeManifestLines`
(master role) AND the merger's `write_manifest` (so a merger-driven
catalog change re-stamps the manifest). They must produce
byte-identical output — see `scripts/merge_dossier_jsonl.py` lines
70-126 for the cross-language contract.

**Who reads:** viewer-mode VideoScan instances (M5, M1) verify the
synced catalog against this manifest before considering themselves
"in sync." Mismatch → MASTER OFFLINE banner.

**Why it matters:** the only check that the bytes on the viewer match
the bytes on the master. Without it, an interrupted rsync would
leave a half-written catalog and the viewer would happily render
corruption.

---

## Backup coverage

### What the "Export Everything" bundle includes today

The bundle export is triggered by:

- The colored badge in the catalog header (green / yellow / orange / red),
  which lives at `ContentView.swift::backupStatusBadge`
- The File → Export Everything menu item

Color thresholds:

| Color | Meaning |
|---|---|
| Green | Backed up in the last 7 days |
| Yellow | 7-30 days old |
| Orange | More than 30 days old |
| Red | Never backed up |

The bundle is a directory `<name>.videoscanbundle/` containing:

| In bundle? | What | Source |
|---|---|---|
| ✅ | `catalog.json` | live records, with dossier fields embedded per-record |
| ✅ | `volumes.json` | per-volume metadata (role, trust, media, retire state) |
| ✅ | `settings.json` | machine-portable subset of PersonFinderSettings |
| ✅ | `people/<name>/...` | entire POI tree (profile + photos, symlinks resolved) |
| ✅ | `manifest.json` | bundle export metadata (counts, sizes, host, app version) |

### What the bundle does NOT include today (gaps)

| Missing | What | Why it might matter |
|---|---|---|
| n/a | `metadata_cache.sqlite` | Cache — re-derived from a scan. Correctly skipped. |
| n/a | merger offsets | Volatile by design. Correctly skipped. |

### Recently closed gaps (2026-06-07)

| Now included | What | What it bought us |
|---|---|---|
| ✅ | `deltas/m{1,4,5}.jsonl` | Belt-and-suspenders against catalog.json corruption. If catalog dossier is ever wiped at restore time, the JSONLs replay back into it (see "JSONL replay recovery" runbook). |
| ✅ | `catalog-manifest.sha256` | Lets a restore verify what came out of the bundle matches what went in. Hash format identical to `manifest.sha256` so `shasum -a 256 -c` works directly. |

A delta dir that's offline at export time (e.g. Crucial2TB unmounted on
MBP) emits a warning but doesn't fail the export — the catalog.json
inside the bundle still has the dossier fields embedded per-record.

Tests pinning the new contract:
`VideoScan/VideoScanTests/BundleDossierDeltaTests.swift` (10 tests).

---

## Recovery procedures (runbook)

### Symptom: catalog dossier dial dropped to <1% after a rescan

**Diagnosis:** the rescan re-created VideoRecord instances without
preserving dossier fields.

**Status:** as of 2026-06-07 this is prevented by
`VideoScanModel+RescanPreservation.swift` (snapshot-and-restore pass
before/after `records.removeAll`). Regression-tested in
`RescanPreservationTests.swift`.

**If it happens anyway:** see "Catalog dossier wiped — JSONL replay
recovery" below.

### Symptom: catalog dossier wiped — JSONL replay recovery

**Preconditions:**

- Dossier JSONLs are intact at `/Volumes/Crucial2TB/dossier-deltas/`.
- The merger script `scripts/merge_dossier_jsonl.py` is present.

**Procedure:**

```bash
# 1. Stop the merger (whichever process is currently running it)
pkill -TERM -f merge_dossier_jsonl
# Verify it's gone:
pgrep -fl merge_dossier_jsonl || echo "merger stopped"

# 2. Delete the offsets file so the next merger pass replays from byte 0
rm -f /tmp/dossier-merger-offsets.json

# 3. Restart the merger
/Users/rickb/dev/VideoScan/scripts/merge_dossier_jsonl.py \
    --delta-dir /Volumes/Crucial2TB/dossier-deltas \
    --interval 60 &

# 4. Watch catalog.json grow as deltas are replayed (idempotent)
watch -n 5 'jq "[.records[] | select(.dossierProcessedAt != null)] | length" \
    ~/Library/Application\ Support/VideoScan/catalog.json'
```

Recovery time: **~1-2 minutes per 1000 records**. A 6000-record
catalog rebuilds in under 10 minutes.

**Regression tested:**
`tests/test_merge_dossier_jsonl.py::TestDisasterRecoveryViaOffsetReset`.
If those three tests are green, this procedure works.

### Symptom: catalog.json is corrupt / unreadable

**Procedure:**

```bash
cd ~/Library/Application\ Support/VideoScan/
# Validate the current file:
jq empty catalog.json || echo "catalog is corrupt"

# Roll back to the previous version:
mv catalog.json catalog.corrupt.$(date +%Y%m%dT%H%M%S).json
cp catalog.json.prev catalog.json
```

If `catalog.json.prev` is ALSO corrupt (rare — would require two bad
writes in a row), restore from the latest bundle export instead:

```bash
# Open the bundle in Finder, copy catalog.json out of it:
cp "/Users/rickb/iCloud Drive/...latest.videoscanbundle/catalog.json" \
   ~/Library/Application\ Support/VideoScan/catalog.json
```

Then run JSONL replay (above) to top up any dossier work the bundle
didn't capture.

### Symptom: POI tree corrupted or destroyed

**Procedure:** import from the latest bundle. The import path validates
each POI before swapping it in, and the displaced original (if any) is
moved to `~/dev/VideoScan/.trash/` rather than deleted.

### Symptom: Crucial2TB SSD failed (dossier deltas gone)

**Today's reality:** as of this document's date, **the JSONLs are not
mirrored anywhere**. If the SSD dies and catalog.json has been wiped,
the dossier work is gone — no replay possible.

The mitigation (planned, see "Improvements" below) is to:

1. Include the JSONLs in the bundle so they ride along to iCloud
2. Daily mirror the deltas dir to a second physical disk

---

## Known weak links — ranked by blast radius

Updated after the 2026-06-07 audit. Each entry has a planned mitigation
linked to a follow-up commit.

1. **JSONL deltas live on ONE drive (Crucial2TB SSD).** If that drive
   dies AND catalog.json is wiped, weeks of dossier compute are
   gone. **Mitigation:** include JSONLs in bundle export + daily
   mirror to a second disk.
2. **POI tree (191 MB) has no separate backup outside the bundle.**
   **Mitigation:** bundle covers it; trust the bundle but make sure
   the badge is honest about staleness (it is).
3. **`.prev` is single-step rotation.** Two bad writes in a row erase
   history. **Mitigation:** daily snapshot rotation keeping last
   N days (planned).
4. **Merger is M4-only.** If Mac Studio is down for days, JSONLs
   keep growing but never reach catalog. No alarm. **Mitigation:**
   merger heartbeat file that an in-app banner checks.
5. **No alarm on "merger stopped."** Same as above.

### Recently mitigated (2026-06-07)

- **`apply_deltas` schema validation** — every known dossier field now
  type-validates before write. Unknown fields pass through
  (forward-compat for new dossier channels). Bad fields are dropped
  with a logged reason; the rest of the delta still applies. A delta
  whose every field is rejected counts as schema-rejected (not
  applied) so the merger log surfaces the upstream worker bug.
  See `scripts/merge_dossier_jsonl.py::DOSSIER_FIELD_VALIDATORS` and
  `tests/test_merge_dossier_jsonl.py::TestSchemaValidation` (10 tests).
- **Merger offsets relocated** from `/tmp/dossier-merger-offsets.json`
  (volatile across reboot) to
  `~/Library/Application Support/VideoScan/dossier-merger-offsets.json`
  (persistent). A one-shot migration shim copies any legacy
  `/tmp` file into place on first run. Idempotent and silent when
  there's nothing to do. See
  `scripts/merge_dossier_jsonl.py::migrate_legacy_offsets` and
  `tests/test_merge_dossier_jsonl.py::TestOffsetMigration` (4 tests).

---

## Tests that pin these contracts

The database design has teeth because tests enforce the invariants
that make recovery possible:

- `VideoScan/VideoScanTests/RescanPreservationTests.swift` (9 tests)
  — proves the rescan-time snapshot/restore of dossier + user-edit
  fields. Prevents the 2026-06-07 wipe from happening again.
- `tests/test_merge_dossier_jsonl.py::TestDisasterRecoveryViaOffsetReset`
  (3 tests) — proves the "delete offsets → replay" recovery channel
  works, that replay is idempotent, and that the merger matches by
  fullPath even after a record rebuild.
- `tests/test_merge_dossier_jsonl.py::TestApplyDeltas` (5 tests) —
  proves field-by-key copy semantics, unrelated-field preservation,
  ordering for multiple deltas targeting one record.
- `tests/test_merge_dossier_jsonl.py::TestAtomicWriteCatalog` (3
  tests) — proves the `.prev` rotation, atomic rename via tmp file,
  graceful first-write.
- `tests/test_merge_dossier_jsonl.py::TestManifestWriter` (7 tests)
  — proves the Python and Swift manifest implementations stay in
  byte-identical lock-step.

If any of those go red, **STOP** — the safety net is broken.

---

## When to update this document

- New file added to the database surface → add a row to the table
- Write contract changes (atomic-rename pattern, schema version) → update
  the relevant section
- Bundle export gains or loses a payload → update the backup coverage
  matrix
- New recovery procedure invented → add to the runbook
- Weak link mitigated → demote from the weak-links list and add the
  test reference to the tests section
