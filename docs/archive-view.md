# Archive View — Timeline over Files (Rick + Claude, 2026-08-19)

## The observation that started this

First real promote through the Archive Helper landed
`1990-1999/1997/1997-xx-xx_Family_CapeCod_1997.dv` (+ `_repaired.mov`) —
correct on disk — but the Archive tab showed the rows as `Clip 01.dv` /
`Clip 01_balanced.mov`. The tab presents the archive as *source files with
an archive column*, when the archive is the one place in the app where the
media is **vetted**: reasonably known dates, repaired audio, human names,
verified copies. Rick:

> Catalog view shows media as-is and helps us organize, repair, analyze.
> Archive contains vetted media. The Archive window should help a user see
> the video story **over time** — a timeline, decades, year by year —
> rather than a raw file view (still available under View).

## The two roles, kept distinct

| | Catalog | Archive |
|---|---|---|
| contents | everything scanned, as found | only promoted, verified media |
| names | whatever the camera/era left | human names (Archive Helper) |
| dates | inferred, often wrong (#166) | gated at promote time |
| job | organize · repair · analyze | **remember · browse · share** |
| natural view | table | **timeline** |

The archive's guarantees (date, name, audio, fixity) are exactly what a
timeline needs — and the timeline is the payoff that motivates doing the
Helper's prep work. Virtuous loop: every promote makes the story view
richer, and gaps in the story view coax the next round of digitizing and
promoting.

## Proposed: Archive window gets a View switch

**View ▸ Timeline** (default) · **View ▸ Files** (today's table, kept as-is).

### Timeline view

Vertical scroll, newest or oldest first (user pref), three zoom levels the
user moves between by clicking headers — the Apple Photos Years→Months→Days
gesture, adapted to a family archive's density:

1. **Decades band** — one card per decade: hero thumbnail, count of videos /
   audio / photos, total hours, the people most seen. A decade with
   nothing is drawn as an honest *gap* ("no media yet from the 1960s —
   tapes in the attic?"), not omitted: gaps are the coaxing surface.
2. **Years within a decade** — a row per year; each year shows its events
   and unclustered items. Undated media appears in a pinned "Undated"
   shelf with a one-click path to the Inspector's date field.
3. **Year detail** — cards per item or event cluster: archive name (the
   human one — `Family_CapeCod_1997`, never `Clip 01`), duration, people
   chips, a filmstrip strip on hover (reuse the existing preview cache),
   play = smart open, right-click = the existing archive menu (journey,
   details, reveal).

**Media kinds on the timeline:** video cards (dominant), audio items
(waveform glyph — interviews, answering-machine tapes), and **milestone
photos**: this is not a photo database, but select photos (weddings,
births, graduations, vacations) earn timeline placement as *markers* —
small, square, clustered — because they anchor the story between videos.
The archive scaffold already has `10_Photos/`; promotion of a photo tags
it `milestone` (a lightweight tag, not a new subsystem).

**Filters** (toolbar): person (POI chips) · media kind · event type ·
decade jump strip. All backed by fields the archive records already carry
(taggedPeople, streamType, dateHint); event type arrives with the
MediaAngel event-tag work.

### Event clustering (phase 2)

Same year + same/adjacent dates + shared people/tags → one **event card**
("Cape Cod, July 1997 — 3 videos, 1 audio, 2 photos"). Sources: date
proximity, filename stems (the Helper's naming makes siblings share a
stem: `_repaired`, `_modernized_YYYY`), CyberBrain event priors later.
Deterministic clustering, Hallie phrases the captions — consistent with
the deterministic-composer decision (2026-08-14).

## Prior art worth borrowing (survey before building)

- **Apple Photos** — Years/Months/Days zoom, hero images, Memories. The
  gold standard for the zoom gesture and density handling.
- **Immich** (self-hosted — aligns with the no-vendor-lock-in preference)
  — virtualized timeline scrubber with year/month bubbles; its open-source
  timeline implementation is directly studyable.
- **PhotoPrism / Mylio** — calendar+timeline hybrids; Mylio's "All Time"
  decade wall is close to our decades band.
- **Google Photos** — the fast drag-scrubber with date tooltip; worth
  copying for a 60-year archive.
- **CollectiveAccess / Omeka (museum world)** — object timelines with
  provenance panels; matches our journey/manifest story on click-through.
- Explicit non-goal: we are not becoming a photo manager. Photos appear
  only as milestone markers.

## Implementation sketch (when scheduled)

- `ArchiveTimelineModel` (pure, tested): archive records → decades →
  years → event clusters; O(records) with the RenderMemo/precompute
  discipline; date from the SAME `ArchiveDateHint` used for foldering, so
  the view and the disk never disagree.
- `ArchiveTimelineView` + the View switch in the Archive tab toolbar;
  Files view untouched.
- **Quick wins to ship first, independent of the timeline:**
  1. Archive tab rows show the **archive name** first (source filename
     as secondary text) — fixes today's confusion outright.
  2. Decade/year section headers in the existing table (cheap grouping).
  3. "Show this file's journey" already landed on the tab (2026-08-19).
- Thumbnails: existing filmstrip/preview cache; hero image = first
  face-bearing frame when Person Finder has one.

## Open questions for Rick

1. Default sort: oldest-first (chronicle) or newest-first (recency)?
2. Do event cards need manual create/merge/split from day one, or is
   automatic-with-rename enough?
3. Milestone photos: promoted through the same Archive Helper (photo
   readiness = date + name only), or a lighter drag-in?
4. Does the timeline become the family-facing surface Hallie links into
   (the published/read-only story for the cousins), while Files stays the
   archivist's bench?
