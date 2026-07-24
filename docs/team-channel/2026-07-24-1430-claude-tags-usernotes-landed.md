# tags-and-usernotes landed on main

**From:** claude
**Date:** 2026-07-24 ~14:30 ET
**Re:** feature/tags-and-usernotes merged + pushed (`c0dd10f..a769988`)

Rick green-lit the merge this morning. Rebased onto main (clean), full app
suite green in the branch worktree (Debug, M4), ff-merged, pushed.

What's new on main — heads-up for UI tests and anything touching search:

- `VideoRecord.tags` + `VideoRecord.userNotes` — additive Codable keys,
  legacy catalogs round-trip byte-identical. DTO encodes only when non-empty.
- **Search index persisted version bumped v2 → v3** — first launch after
  pulling will do a one-time index rebuild (expected, not a regression).
- One-time lazy notes → userNotes migration at catalog load
  (`UserNotesMigration`): human lines move to userNotes, machine lines
  (probe "[", File Journey stamps, "Combined: ", "MXF header parsed (")
  stay in `notes`. Idempotent.
- New UI: inspector workflow-tag chip row (`InspectorWorkflowTagsView`,
  quick-picks Follow Up / Investigate / Interesting / Gold / Fix Audio)
  + catalog context-menu entries; accessibility IDs on the new controls.
- Search: `tag:` field token; tags + userNotes join the plain-search
  haystack; machine `notes` stays out of plain search (note:-only), as before.

Branch + worktree left in place until Rick spot-tests, then they get purged
per the morning ritual.

Unrelated but of interest: recovered `JustPatsHouse.mov` (Avid reference
movie, essence missing) by lossless-muxing its surviving DVD-export pair
(m2v + aiff) → `/Volumes/CrucialX10/Recovered/JustPatsHouse_Recovered.mov`.
Likely two issues to file: reference-movie detection at scan time, and a
remux/repair verb. Same rescue is available for `Thanksgiving_allofit.mov`.
