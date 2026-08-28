# Family-tree one-time ingest / compile — plan and first results (2026-08-28)

Rick, 8/28: Donna's FamilySearch pull finished. "We are willing to pay a one-time
price to ingest the file and connect everything between the trees so subsequent
queries will be extremely fast … link contemporary people to the tree behind
the scenes … through Hallie Mae anyone with access has full read permission;
write permission = admin (Rick), later."

## Inputs (raw, immutable, on the Master Archive)
| pull | people | families | size | root |
|---|---|---|---|---|
| `GEDCOM/familysearch-tree-20generations.ged` | 16,383 | 10,387 | 70 MB | Richard Harding Breen Jr (GVQV-NW3) |
| `GEDCOM/pulls/familysearch-donna-20generations.ged` | 31,084 | 19,737 | 133 MB | Donna Hudson (G2CL-86B) |

Neither contains living contemporaries (FamilySearch privacy); those are local-only
(feature/people-kinship: typed kinship edges on POI profiles, never exported).

## Pipeline (built today on `feature/tree-ingest-compile`)
```
videoscan-tree-ingest --out <compiled-root> --report merge-report.json rick.ged donna.ged
  parse (GedcomFamilyGraph(fileURL:))            2.3 s + 4.3 s
  merge by FSID (GedcomFamilyGraph+Merge)        89 ms   → 39,250 people, 8,217 shared
  TreeIndex (CSR topology + name postings)       264 ms
  compile (GedcomCompiledTree codec 2) → verify → promote (FamilyGraphCompiledStore)  193 ms
                                                          total 7.1 s, 900 MB peak RSS, 16 MB artifact
```
The app (`FamilyGraphFileLoader`) now loads the promoted multi-source generation
outright while every recorded source is unchanged (`FamilyGraphCompiledStore.loadCurrent`);
a re-pull of either file makes it stale and the newest-file path takes over.
Launch never parses a GEDCOM again.

Codec 2 adds: `rootPersonIDs` (list), `sourceFileNames`, `isMergedArtifact`,
`droppedLineCount`, `headNote`. `FamilyGraphCompiledStore` moved to VideoScanCore
(public, injected log) so CLI, HallieShellCLI and app share one generation store.

## First cross-tree answer
Rick ↔ Donna: nearest common ancestors Martha Lamson (b. before 13 Jan 1633),
Matthew Rice, Susanna Gleason, Thomas Pratt — depth 10/11 → **9th cousins once
removed**; also Daniel Cushing I at 11/11 → 10th cousins. 8 ms on the parsed graph,
9 ms on the decoded artifact.

## Merge report (merge-report.json, 1.4 MB)
- 53 field disagreements (place spelling, name casing) — first source kept, second recorded.
- 4,638 `familyKeptSeparate` — verified sample: these are FamilySearch's OWN
  duplicate persons inside Donna's pull (e.g. two `Thomas /Barclay/` records @I70@/@I104@),
  not merge errors. Future: "possible duplicate" hint surfaced to Rick, resolved on FS.
- 0 unmatched (every record carries `_FSFTID`).

## Next
1. codex review of #783/#784/#785 + this integration branch; merge order perf → two-root → kinship → ingest.
2. Run the CLI against production `family-tree/compiled/` (after merge; Rick launches app).
3. Common-ancestor acceleration: today's walk is 8 ms at 39k — fine; precompute for POI pairs into CyberBrain.
4. CyberBrain "informed" layer: kinship facts for contemporaries (Tim, sons, in-laws → FSID anchors),
   notable-ancestor lines, on-this-day — written as citable items so qwen phrases from data.
5. HallieShellCLI/web: load the artifact (read for anyone with access); write = Rick only (later).
