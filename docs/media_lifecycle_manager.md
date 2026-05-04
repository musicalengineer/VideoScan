# Media Lifecycle Manager

**Status:** Design proposal (revised)
**Last updated:** 2026-05-04
**Author:** Rick + Claude
**TL;DR:** Restructure the main app into four tabs that mirror the natural media lifecycle — **People → Catalog → Triage → Archive** — backed by *one* unified catalog database. Each tab is a filtered lens on the same data; lifecycle progression is a state change, not a data move.

---

## History

The first version of this design (2026-04-23) proposed a separate **Window > Media Lifecycle** (Cmd+L) running alongside the main app, with two modes: Keeper Pipeline and Junk Review.

The 2026-05-04 revision supersedes that with a **four-tab restructure of the main app**. Reasons:

- The lifecycle is not a side-tool — it *is* the central workflow. Hiding it behind a separate window understates that.
- A side window competing with the Catalog tab for attention duplicates UI surface (two tables, two filter sets).
- The four-tab pattern makes the workflow self-explanatory: a media file visibly traverses People → Catalog → Triage → Archive as work progresses.

The data model and junk-scoring heuristics from the original doc are preserved (sections below). What changed is *where the user encounters them*.

---

## The Four Tabs

```
 ┌─────────┬──────────┬─────────┬──────────┐
 │ People  │ Catalog  │ Triage  │ Archive  │
 └─────────┴──────────┴─────────┴──────────┘
     who      what      judge     secure
```

| Tab | Purpose | Default content |
|---|---|---|
| **People** | Identify and train recognition for family members. POIs, reference photos, Find Person, Identify Family. | Existing People tab (unchanged). |
| **Catalog** | Raw inventory of all media files seen across all scanned volumes. The "what exists" view. | All `VideoRecord`s, **default-hides `lifecycleStage == .archived`** (toggle to show all). |
| **Triage** | The triage workspace. Big Junk / Keep / Repair buttons; opinionated for fast curation. | Records needing triage: untriaged, plus `.recoverable` and `.suspectedJunk` waiting for confirmation. |
| **Archive** | The vault. Only files verified safe with 3-2-1 redundancy. | Records where `lifecycleStage == .archived`, with master / local / cloud status per row. |

The tabs are reading projections of the same catalog. **No file is moved between databases**; only its state advances.

---

## The Two-Axis State Model

Every `VideoRecord` carries two orthogonal state fields. Mixing them is what made the original `unreviewed` enum slightly muddled.

### Triage axis — `mediaDisposition` *(already exists)*

What the user **thinks** about a file. Surfaced primarily in the Triage tab.

```swift
enum MediaDisposition: String, Codable {
    case unreviewed
    case important          // has family or manually marked
    case recoverable        // worth repairing (bad audio, broken container, etc.)
    case suspectedJunk      // junk-scoring flagged it; waiting for user confirmation
    case confirmedJunk      // user confirmed; safe to delete (after backup verify)
}
```

### Lifecycle axis — `lifecycleStage` *(NEW)*

Where the file **is** in the pipeline. Surfaced primarily by which tab shows it.

```swift
enum LifecycleStage: String, Codable {
    case cataloged   // scanned; knows it exists. The default for any newly-seen file.
    case reviewing   // user has touched this file in Triage (auto-set on first action).
    case archived    // explicitly promoted with verified 3-2-1 redundancy.
}
```

The two axes give you queries the old single enum couldn't:

| Query | Filter |
|---|---|
| Important media still being reviewed (the to-archive backlog) | `disposition == .important && stage == .reviewing` |
| Junk safely archived for completeness | `disposition == .confirmedJunk && stage == .archived` |
| Untriaged in the Triage queue | `disposition == .unreviewed && stage != .archived` |
| What's in the vault | `stage == .archived` |

---

## How a File Moves Through

1. **Scan finds it** → `lifecycleStage = .cataloged`. No user action.
2. **User acts on it in Triage** (sets disposition or opens detail) → `lifecycleStage = .reviewing` automatically. Stays here until promoted.
3. **User promotes to Archive** via an explicit action button. The app **verifies 3-2-1 first**:
   - Master copy reachable on its source volume?
   - At least one local LTA copy on a different volume?
   - At least one cloud copy?
   If all pass → `lifecycleStage = .archived`, hashes/paths/dates recorded. If any fail → operation refused with a clear "missing X" message.

The promotion gate is the critical UX detail. The whole point of the Archive tab is "I trust this is safe." If we ever auto-promote on heuristics, the indicator becomes untrustworthy and the tab becomes worthless.

---

## Tab-by-Tab Detail

### People (unchanged)

POI gallery + reference photos + Find Person sub-tab + Identify Family sub-tab. The *who* layer that informs the rest.

### Catalog

- Same row data and columns as today.
- New: a "Hide Archived" toggle in the toolbar, **default ON**. Keeps the working catalog focused on files that still need work.
- Lifecycle stage shown in a small badge column (`Cataloged` / `In Triage` / `Archived ✓`).
- Right-click menu gains "Send to Triage" (sets disposition + stage if not already there).

### Triage *(new tab)*

The opinionated triage workspace. Layout:

```
┌─────────────────────────────────────────────────────────────────────┐
│  Triage                              [Volume ▾] [Person ▾] [Sort ▾]│
├──────────────┬──────────────────────────────────────────────────────┤
│              │  ┌──────────────────────────────────────────────┐   │
│ FILTERS      │  │ [thumbnail]  Christmas-1990-something.mov    │   │
│              │  │              480p · 28:43 · 4.2 GB           │   │
│ ○ Untriaged  │  │              Donna, Tim detected · 17m 46s   │   │
│   (847)      │  │                                               │   │
│ ◐ Important  │  │  ⚠ Junk?   ❤ Keep   🔧 Repair                │   │
│   (38)       │  │  Health: ✓ playable · ⚠ no audio              │   │
│ ◐ Suspected  │  │                                               │   │
│   Junk (312) │  ├──────────────────────────────────────────────┤   │
│ ✗ Confirmed  │  │ [thumbnail]  …                                │   │
│   Junk (94)  │  └──────────────────────────────────────────────┘   │
│              │                                                      │
│ ◐ Recoverable│                                                      │
│   (12)       │                                                      │
│              │                                                      │
│ Family:      │                                                      │
│ □ Donna      │                                                      │
│ □ Timmy      │                                                      │
│ □ Matt       │                                                      │
└──────────────┴──────────────────────────────────────────────────────┘
```

Key UX:
- **Big disposition buttons** (Junk / Keep / Repair) — single click to triage; keyboard shortcuts (J/K/R).
- **Bulk actions**: select N rows → triage all at once.
- **Filter rail** by disposition, by detected person, by health.
- **One row per logical file** (deduped by `duplicateGroupID`) so you triage the *content*, not three copies of it.
- **Auto-set `lifecycleStage = .reviewing`** on first action.

### Archive *(rebuilt as the Vault)*

Only `lifecycleStage == .archived`. Each row is a logical file with 3-2-1 status visible:

| Filename | Date | Person tags | Master | Local LTA | Cloud LTA | Status |
|---|---|---|:---:|:---:|:---:|:---:|
| Donna_compilation_2026… | 2026-05-04 | Donna | ✓ Mac Studio | ✓ Crucial2TB | ✓ iCloud | 🟢 Golden |
| TimmyPart1.m4v | 1992 | Timmy, Donna | ✓ Mac Studio | ✓ Crucial2TB | — | 🟡 Partial |
| OldHomeMovie.dv | 1989 | unknown | ✓ Mac Studio | — | — | 🔴 At risk |

Status semantics:
- 🟢 **Golden** — master + ≥1 local backup + ≥1 cloud copy, hashes verified within last N days.
- 🟡 **Partial** — master + only one of {local, cloud}.
- 🔴 **At risk** — only master.

Click a row → detail sheet showing every known physical copy, paths, sizes, hashes, last-verified date, and a "Re-verify" button.

The "At risk" view is the actionable signal — it tells you what to back up next. So even if a file is "archived," the Vault is honest about whether it's actually safe.

---

## Cloud-Copy Detection

This is the design question with the most uncertainty. Three options, in order of complexity:

1. **Path heuristic** *(v1, recommended for first ship)*: a copy whose path contains `/Mobile Documents/com~apple~CloudDocs/` or `~/Library/Mobile Documents/` is treated as "in iCloud."
2. **Manual tagging**: a "Mark as cloud-archived" action that records `iCloudRecorded: Date` after the user has dragged files into iCloud.
3. **PhotoKit / NSURLUbiquityIdentifier metadata**: most reliable but requires the file to live inside the user's iCloud Drive folder structure, which not all of Rick's archive flow uses.

Start with (1). Fall back to (2) when the heuristic mis-classifies; build (3) only if the others prove insufficient.

---

## Data Model Changes

Additions to `VideoRecord`:

```swift
var lifecycleStage: LifecycleStage = .cataloged   // NEW

// Vault-state fields, populated only when stage == .archived
var masterVolume: String? = nil
var localBackupLocations: [String] = []
var cloudCopyLocations: [String] = []
var lastVerifiedAt: Date? = nil
var lastVerifiedHash: String? = nil
```

`mediaDisposition` already exists — no change required.

Persistence: same as today — `CatalogStore` saves the catalog as one JSON snapshot. New fields decode-with-default so v1 catalogs load without migration.

---

## Junk Scoring (preserved from v1 of this doc)

The heuristics that propose `mediaDisposition = .suspectedJunk`. User must confirm before any deletion happens.

Signals (each weighted; sum produces `junkScore`):

- Tiny file (<1 MB)
- Very short duration (<3s)
- All-black or all-white frames (single thumbnail check)
- Filename matches throwaway pattern (`IMG_NNNN.MOV` with no faces, screen-recordings, accidental clips)
- Duplicate of a higher-quality copy already in catalog (lower-res / lower-bitrate versions when a master is known)
- ffprobe reports broken/incomplete stream
- Zero faces detected after PersonFinder pass

Each signal contributes to `junkScore` and a human-readable line in `junkReasons`. Files with score above threshold get auto-suggested in the Triage tab's "Suspected Junk" filter, with reasons displayed inline. Nothing deletes without explicit user confirmation.

---

## What This Does NOT Do

- **Auto-delete anything.** Every deletion requires explicit user confirmation.
- **Auto-promote to Archive.** Promotion is always a user action, gated by 3-2-1 verification.
- **Replace Catalog.** Catalog is the inventory; Triage is the curation workspace; Archive is the vault. Three lenses on the same data.
- **Replace Compare & Rescue.** C&R does the cross-volume comparison. The Vault consumes those results to display backup status.
- **Manage the physical archive process.** Writing to LTA media, uploading to iCloud — those happen outside the app. The app tracks *that* it happened, with verification.

---

## Implementation Phases

Re-scoped for the four-tab restructure.

### Phase 1: Schema + Catalog "Hide Archived" toggle (MVP foundation)

- Add `LifecycleStage` enum + field on `VideoRecord` with backward-compat default decode.
- Add the toggle in Catalog toolbar; default-hide archived rows.
- Add the lifecycle-stage badge column in Catalog.

Effort: 2-3 hours. Lets every other phase have somewhere to write its state.

### Phase 2: Triage tab + Junk Scoring

- New tab in `ContentView`.
- Filtered/opinionated view with Junk/Keep/Repair buttons + keyboard shortcuts.
- Junk-scoring engine populating `junkScore` + `junkReasons`.
- Auto-set `lifecycleStage = .reviewing` on first action.

Effort: 1-2 days. This is where Rick spends his daily curation time.

### Phase 3: Archive/Vault tab rebuild

- Replace current Archive tab content with the Vault layout.
- 3-2-1 status computation per row (uses `duplicateGroupID` + path heuristics).
- Detail sheet with all known copies + Re-verify action.
- Cloud-copy detection (path heuristic).

Effort: 2-3 days.

### Phase 4: Promote-to-Archive action + verification gate

- "Promote to Archive" button in Triage (and Catalog detail).
- Verification step: confirm master + local LTA + cloud LTA copies exist; record hashes/paths/dates.
- Only on success → `lifecycleStage = .archived`.

Effort: 1 day.

### Phase 5: Refinements (post-MVP)

- Bulk promote selections.
- Per-volume progress bar ("How clean is this drive?").
- "Send to Triage" right-click in Catalog.
- Compare & Rescue integration to refresh backup-verification timestamps.
- Manual cloud-tagging fallback if path heuristic isn't enough.

Each item is independent; ship as appetite allows.

---

## Connection to Existing Features

- **Catalog scan** provides the file inventory and metadata.
- **PersonFinder** provides the "has family" signal that feeds `disposition = .important`.
- **DuplicateDetector** identifies copies across volumes — feeds the Vault's local-backup column.
- **Compare & Rescue** verifies cross-machine backup status — refreshes Vault verification timestamps.
- **CombineEngine** resolves orphaned A/V pairs before lifecycle tracking.
- **Junk scoring** reuses heuristics from `catalog-aided-face-detection.md` and `issue-08`.

All inputs already exist or are planned. The four-tab restructure is the **integration point** that turns those raw signals into a coherent workflow.

---

## Open Design Questions for Rick

1. **Catalog: hide archived by default, or show all with a badge?** Current proposal: hide by default with toggle. Alternative: show all, badge archived rows. Hide-by-default is cleaner for daily work; show-all is easier when looking for cross-references.
2. **Cloud detection v1**: path heuristic only, or path + manual tagging from the start?
3. **Verification freshness**: how recently must hashes have been re-verified for a file to display as 🟢 Golden? Suggest 90 days; configurable.
4. **Strict vs lax 3-2-1**: must Vault require all three (master + local + cloud), or is master + local + offsite-NAS-backup also Golden? Suggest strict for first ship; loosen if the bar is too high for older footage.
