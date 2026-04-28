# Tagging Media with People

**Status:** Design draft. Captures the data model, tag sources, conflict rules, and a phased plan so the implementation lands consistently and we don't waste manual tagging effort to a future re-run.

**Goal:** Every catalog record carries a `contains: [people]` tag set. Tags are populated from a mix of face recognition, Apple Photos, filename heuristics, neighbor propagation, and manual review. Once tagged, the catalog becomes a queryable index — "show me everything with Donna and Tim from 2010" — and the Family Legacy reel-building workflow becomes a query, not a curation chore.

---

## Data model

```swift
struct PersonTag: Codable, Hashable {
    /// Canonical POI sanitized name (matches POIStorage.sanitize). NOT the
    /// display string — collisions like "Tim" vs "Timmy" matter.
    var personID: String

    /// Where this tag came from. Drives conflict resolution and re-run rules.
    var source: TagSource

    /// 0.0 – 1.0. Manual tags get 1.0. Auto tags carry the algorithm's score.
    /// Used for ranking review UIs and for "high-confidence-only" filters.
    var confidence: Float

    /// When the tag was added. Auto-tags from re-runs replace older auto-tags
    /// of the same source; manual tags never expire.
    var addedAt: Date

    /// For `.faceMatch` tags: presence duration in seconds (helps weight
    /// "Donna for 30s" higher than "Donna for 0.5s").
    var presenceSeconds: Double?

    /// Back-link to the scan job that produced this tag. Helps debugging
    /// ("which run mis-tagged this?") and bulk un-tag operations.
    var jobID: UUID?
}

enum TagSource: String, Codable, Hashable {
    case manual              // user added by hand — ground truth
    case faceMatch           // VideoScan's own face recognition
    case applePhotos         // imported from Apple Photos people
    case filenameHeuristic   // POI name/alias matched in filename tokens
    case propagated          // inferred from neighboring records (siblings in folder, time-adjacent)
}

extension VideoRecord {
    /// Multiple tags per person are allowed (e.g. faceMatch + manual confirm).
    /// Conflict resolution rules (below) decide which wins for display.
    var contains: [PersonTag]
}
```

**Key choices:**

- **Tag by personID, not by name string.** "Tim" and "Timmy" are distinct POIs; never collapse them. Display name is looked up from the POI store at render time.
- **Multi-source by design.** A single record can carry both `.faceMatch` and `.manual` tags for the same person. The algorithm tracks each independently so re-runs don't trample manual confirmations.
- **Confidence + presence.** "Donna appeared once for 0.4s with confidence 0.51" is a different signal than "Donna appeared continuously for 32s with confidence 0.78". Both matter; both get retained.

---

## Tag sources

Five sources, each with explicit rules for when a tag is created, updated, or removed.

### 1. Face match (the primary signal)

When a PersonFinder job for `<person>` completes, walk its hit ranges per record. For each record:

- **Add tag** when `max_confidence ≥ 0.60` AND `presence ≥ 5.0s` (mirrors existing PersonFinder commit thresholds; tunable in Settings).
- **Tag stays** until a subsequent run for the same person on the same record produces a result.
- **Re-run rule:** a new `.faceMatch` tag for `<person>` on a record *replaces* any prior `.faceMatch` tag for that person on that record. It does NOT touch other sources (manual, Apple Photos, etc.).
- **No-result is not a remove.** If a re-run finds no hits, the existing tag stays — recognition could have failed for benign reasons (different engine, different threshold). Removal is a manual or explicit "purge" action.

### 2. Apple Photos people (one-time import + periodic refresh)

Apple Photos has already done massive face clustering across the user's library. Names attached to those clusters are high-precision (Apple is conservative about auto-naming).

- **Source:** `PHAssetCollection` with `assetCollectionSubtype == .smartAlbumPeople` on macOS via the Photos framework, gated by `PHPhotoLibrary.requestAuthorization`.
- **Mapping UI:** First import shows "Apple Photos has these named people — for each, pick a matching VideoScan POI or skip." Mapping is saved to UserDefaults so subsequent refreshes are silent.
- **Caveat:** Apple Photos asset IDs (`localIdentifier`) tell us which *photos* contain a person. Mapping that to *videos in the catalog* is via filename / date / size match. Imperfect but high-precision when it does match.
- **Confidence:** 0.95 — Apple's clustering is good but not infallible.

### 3. Filename heuristics (cheap and useful)

Run at catalog ingest and on POI add/edit. For each record, tokenize `filename + path` (split on `_`, `-`, `.`, ` `) and check against each POI's name + aliases.

- `Donna_birthday_2020.mov` + POI `donna` → `.filenameHeuristic` tag, confidence 0.80.
- `IMG_1234.MOV` → no tags.
- Use word-boundary match, case-insensitive; do NOT substring-match (avoids "tim" matching "timestamp").
- Cheap enough to run on every catalog change.

### 4. Propagated tags (suggestions, not commitments)

Files in the same folder, or shot within N minutes of each other, often contain the same people. This is a strong prior worth surfacing — but it's also where false positives bloom, so we **don't auto-commit** propagated tags.

- Compute siblings: same parent folder OR `|capturedAt - other.capturedAt| ≤ 5 min`.
- For each tag on a sibling, propose the same tag on this record with `source: .propagated`, confidence = sibling's confidence × 0.7.
- Surface in a "Suggested Tags" tray in the record detail UI. User accepts (promotes to manual) or dismisses.
- Never auto-promotes without user confirmation.

### 5. Manual (ground truth)

User clicks "Add Person" on a record, picks a POI, done. Confidence 1.0.

- **Manual wins forever.** No algorithm rewrites or removes a manual tag. The only way to remove is via the UI.
- **Manual confirms an auto-tag** by upgrading it: when the user clicks the checkmark on an auto-tag, we keep the original `.faceMatch` tag (for provenance) and add a parallel `.manual` tag. Display deduplicates by personID.

---

## Conflict resolution

When multiple tags exist for the same `personID` on a record, the display layer collapses them with this priority:

```
manual > applePhotos > faceMatch > filenameHeuristic > propagated
```

The displayed confidence is the max across all sources. The displayed source badge is the highest-priority one. The full tag list remains in the record for debugging / "show me what each algorithm thought."

**Removal semantics:**

- "Remove tag" from the UI removes ALL tags for that personID from the record — with a confirmation dialog if any source was `.manual`.
- "Re-run face detection" only touches `.faceMatch` tags.
- "Re-import Apple Photos people" only touches `.applePhotos` tags.

---

## Persistence

Tags live on `VideoRecord` and ride along with the existing catalog snapshot. Concrete steps:

1. Add `contains: [PersonTag] = []` to `VideoRecord`. Codable, default empty, `decodeIfPresent` so old catalog files load cleanly.
2. Bump `CatalogSnapshot.currentVersion` from 2 to 3. Old snapshots still load.
3. Bump `BundleManifest.currentVersion` from 1 to 2 — a v2 bundle just means "catalog snapshot may carry tags." v1 importers gracefully ignore.
4. `BundleExportImport` round-trips tags for free (they're inside the records).

**Index for fast queries.** Build an in-memory inverted index `[personID: Set<recordID>]` on catalog load. Update incrementally when a tag is added/removed. Lets "show me all records containing Donna" be O(1) instead of a full scan. Build cost is trivial (~50ms for 10k records).

---

## Search and browse — the payoff

Once tags exist, several UIs become near-trivial:

- **Boolean people filter** in the catalog view: chips for "with Donna AND Tim", "without Rick", date range, volume.
- **POI tile counts** in the People gallery: "Donna · 412 clips · 18 h 32 m". Click drills into the tagged subset.
- **Compile reel by query** in Combine/Render: instead of running face detection for a reel, run it once globally to populate tags, then build reels by querying the tag index. Re-runs are seconds, not hours.
- **Co-occurrence view** ("who appears with Donna most?"): groundwork for a family-tree/relationship surface later.
- **Untagged review queue:** records with no people tags after all auto-passes — surfaces things the user might want to manually tag (or files that genuinely have no people in them, which is a useful signal too).

---

## UI surfaces

**Catalog row.** Small avatar dots at the right edge of each row — one dot per tagged person, max 4 visible with "+N" overflow. Tooltip lists names. Source-aware: dim dots for unconfirmed propagated suggestions.

**Record detail sheet.** Existing detail expands with a "People" section:
- Confirmed tags (chips with avatar + name + remove button)
- Unconfirmed auto-tags (chips with checkmark + dismiss buttons)
- Suggested propagated tags (chips with accept + dismiss)
- "Add person" dropdown for manual

**People gallery tile.** Each POI tile shows count + duration. Click navigates to a filtered catalog showing only records tagged with that POI.

**Tag review queue.** New mini-window or sheet: "Review unconfirmed tags." Walks the user through `.faceMatch` and `.applePhotos` tags ranked by confidence descending, with thumbnail and quick confirm/remove. Cleans up the long tail efficiently.

**Search tab.** A combinator: chips for people (AND/OR/NOT), date range slider, volume filter, stream-type filter. Output is a record list shareable as a reel target or CSV export.

---

## Phased plan

| Phase | Deliverable | Approximate effort |
|---|---|---|
| **0** | `PersonTag` + `VideoRecord.contains` + catalog snapshot v3; in-memory inverted index. No UI changes. | ~half day |
| **1** | PersonFinder writes `.faceMatch` tags on job completion. Catalog row shows avatar dots. Record detail shows tag list + manual add/remove. | ~1 day |
| **2** | Filename heuristic pass at catalog ingest. Tag review queue UI. | ~1 day |
| **3** | Apple Photos people import + mapping UI. | ~1–2 days |
| **4** | Boolean people filter in catalog view. POI tile counts. | ~1 day |
| **5** | Propagated tag suggestions (siblings + time neighbors). | ~half day |
| **6** *(payoff)* | "Compile reel by query" — Combine/Render reads from tag index instead of running face detection. | ~1 day |

Phases 0–2 are the load-bearing core. Once those land, the rest is mostly UI and integration polish.

---

## Open questions

1. **Confidence threshold for auto-commit.** Default 0.60/5s mirrors PersonFinder's existing commit thresholds — but the right value for "this record contains Donna" might be stricter than the right value for "this clip is worth extracting." Calibrate against ground truth from the find_person CLI runs.
2. **Apple Photos video coverage.** Apple's people clustering operates on still frames. Whether it reliably tags videos (vs. just photos) needs probing. If video tagging in Apple Photos is sparse, this source is mostly useful for the bootstrap pass.
3. **Multiple people per face match job.** Current PersonFinder runs one POI per job. Tag indexing assumes per-job scope. If a future "scan for everyone" pass exists, the scope rules need a rethink — tags from a multi-POI job should still update each person's tags independently.
4. **Tag deletion on POI deletion.** Deleting a POI ("Tim") should optionally cascade-remove all tags referencing it. UI confirmation prompt: "Tim has 247 tags across 198 records. Remove tags too? [Yes / Just delete POI]."
5. **Tag history vs. current.** Right now we replace `.faceMatch` tags on re-run. Should we instead append a new tag and keep history (for "this record had 0.51 confidence in run A but 0.78 in run B")? Probably not worth the storage; calibration via the find_person CLI is the right tool for that question.
6. **Cross-machine tag sync.** The bundle round-trips tags automatically (they're inside `VideoRecord`). But if Mac and iPad both edit tags between syncs, last-writer-wins. Probably fine for personal use; flag here so we don't promise more than we deliver.

---

## Why this is the right next thing after junk triage

The North Star is "find the people you love in your home videos." Face recognition gets you halfway there — it identifies people in raw footage. **Tagging is the layer that turns one-time recognition runs into a persistent, queryable index.** Without tags, every reel-building task re-runs face detection from scratch. With tags, recognition runs once globally, then every downstream operation (browse, search, compile, family-tree) reads from the index.

It's also the missing piece for the Family Legacy long-arc: "Send Donna's grandkids the highlights of her with the family" stops being a manual curation job and becomes a 30-second query.
