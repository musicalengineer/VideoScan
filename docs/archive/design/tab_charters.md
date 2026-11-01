# Tab charters

Agreed with Rick on 2026-10-11. Each tab answers one question. Before adding a
feature, name the tab whose question it answers. If none fits, the feature is
in the wrong place.

## Two rules that keep the code clean

1. **Tabs own workflows and queues. Actions are shared.** An action such as
   Promote, Move to Trash, Repair… or Play can have a button in several tabs,
   but it has exactly one engine (one code path, one proof, one log line). A
   second button is fine. A second implementation is the smell.
2. **Triage is a side lane, not a stage.** The happy path is
   Storage → Catalog → Archive. A file shows up in Triage because it has a
   reason to (an issue, a copy, a cleanup or event question). It never leaves
   the Catalog to get there; Triage is a lens over the same records.

```
Storage ──▶ Catalog ──── Promote ────▶ Archive
               │                          ▲
               └──▶ Triage (issues, ──────┘
                    Events, Cleanup)
People · Family Tree enrich every tab · Ask Hallie Mae reads all of it
```

## Storage: "Where does it live, and are the drives healthy?"
Connect or scan a drive → see what it holds and how full it is → drive health →
Migrate between drives → Retire a drive → off-site copy.
Not here: deciding what to delete. "Need space?" links to Triage ▸ Cleanup.

## Catalog: "What do I have?"
Ingest/import → identify (ffprobe, dates, metadata, background analyzers) →
search, sort, browse → inspect (⌘I), play → quick actions: **Promote** (the
clear-cut master), Reveal, ⌘⌫ Move to Trash (Finder-like; it warns when the
file is the only copy).
Shows an Archive Angel "ready" badge; the recommender's review queue lives in
Triage.
Moving out: duplicate detection and Copies & Advice (→ Cleanup), the "deleted
label" footer sheet (removed), Combine (→ Repair…).

## Triage: "What needs attention before it can be kept or let go?"
- **All Needing Triage**: per-file decisions: Keep/Important, Repair…, Junk,
  **Promote** once fixed.
- **Events**: group footage by occasion; pick the master; mark the clips as
  covered. Compare Footage lives here.
- **Cleanup**: the only place files leave in bulk. Rows are risk-ranked: extra
  copies ☑, junk you confirmed ☑, superseded ☐, accidental imports ☐, needs a
  look ☐. Each row shows files, GB freed and See files…. Only copies never
  appear. Copies are proved byte for byte before anything moves; Trash only.
  Archive Angel junk suggestions feed "needs a look".
- **Archive Angel recommender**: its promote suggestions to review.
- Workbench (Under Construction / In Workspace): the to-do list.

## Archive: "What are we keeping forever?"
Receive promoted files → verify fixity → file by decade on the timeline →
read-only (Update… for name and date only) → off-site copy.
Never: bulk delete.

## People: "Who is in it?"
Reference photos → find a person across footage → person pages → their
appearances feed Events and dates.

## Family Tree: "How are we related?"
GEDCOM pull and merge → tree → kinship; feeds People names and Hallie.

## Ask Hallie Mae: "Tell me about…"
Reads everything, proposes, never changes files.

## Next
List every feature that sits in the wrong tab today, or has more than one
implementation of a shared action. That list is the plan for the code cleanup.
Design Cleanup and Events against this charter, with mockups before code.
