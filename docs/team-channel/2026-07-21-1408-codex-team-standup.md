---
from: codex
to: rick, claude
re: VideoScan team standup — 2026-07-21
date: 2026-07-21T14:08:08-04:00
---

# Codex standup — July 21

## Current state

- `main` and `origin/main` are synchronized at `7c8fc4f`.
- Overnight catalog/opening/cover-art work is integrated and pushed.
- C3 remains the accepted production POI rule (`minimumHits = 7`).
- C5 formally failed promotion: it tied C3 in one repeat and improved in the
  other, so the gain was not reproducible and C5 remains off `main`.
- The working tree contains active uncommitted work owned by other sessions;
  Codex will preserve it and will not perform broad cleanup or integration.

## Verified deliverables

- Smart QuickTime/VLC selection is unified across Catalog, Archive, and People,
  with an explicit **Open in VLC** action.
- Attached cover art is no longer classified as a real video stream during new
  scans.
- The cover-art catalog purge is implemented with a live recount and recovery
  snapshot. The last read-only count was 2,231 records. It changes catalog
  records only, never media files, and remains behind Rick's explicit click.
- The prior integrated suite recorded 2,969 passing tests / 431 suites. The
  remaining full-gauntlet limitation is environmental: XCUITest needs the M4
  desktop awake and unlocked.

## POI next step

- Stop tuning small rule changes against the same 26 clips.
- C4's learned classifier remains the strongest development candidate, but an
  honest promotion grade requires a sealed, previously unseen Donna/NotDonna
  holdout labeled by Rick.

## Decisions / actions for Rick

1. Run the cover-art purge when comfortable and retain the logged recovery
   snapshot until the catalog is spot-checked.
2. Spot-test QuickTime/VLC routing on representative real files.
3. If desired, grant an awake/unlocked M4 window for the complete five-flow UI
   gauntlet.
4. Assemble/seal the new POI holdout when ready; until then, C3 stays production.

## Schedule acknowledgement

Rick's working-rhythm document is clear. The clock schedule is planning input,
not automatic permission for M4 UI automation; Rick's current declared state
takes precedence, and M5/M1 are preferred for long builds and evaluations.

— Codex (Manager)
