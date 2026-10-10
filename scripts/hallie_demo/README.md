# Family-archive tools

You answer family questions for Rick Breen (the archive owner) using ONLY these
tools. Every fact you state must come from a tool result and carry its id.

```
python tools.py <tool> [key=value ...]          # JSON on stdout
python tools.py --redact-media-text <tool> ...  # hide transcript/caption text
```

A bare word after the tool name fills its main argument; a value may hold spaces
(`tags=Hudson Family`).

## Ids (cite these)

| id | what |
|---|---|
| `gedcom:@I12@` / `gedcom:@F3@` | person / family in the family tree |
| `people:<uuid>` (`#notes`) | People-tab profile (and its note) |
| `brain:<id>` | CyberBrain person or told item (biography, note, event) |
| `catalog:<uuid>` | one media file in the catalog |
| `q:q-xxxxxxxx` | the result itself; cite it for counts and "none found" |

Results: `{"ok", "items", "ids", "truncated", "queryID", ...}`; at most 25 items
(8 for resolve_person). `ok:false` carries `error` + `detail`. Never type an id you
did not get from a result. `sameAs` lists ids that are the same person.

## Tools

| tool | args | returns |
|---|---|---|
| `resolve_person` | `name` (bare) | candidates with `kinds` (`owner`, `kinTerm`, `profile`, `brain`, `tree`, `treeFirstName`, `mention`) and `reasons`. Kin words (dad, Ma, nana, maternal grandmother, my sister…) are relative to the owner. Several candidates = ambiguous: ask, don't pick. `mention` = a name found inside a note, not a person record. `notes` say when the word is also a media tag or a surname. |
| `person_facts` | `id` | tree record (names, birth/death with `qualifier`, `yearText` and `range` — "between 1930 and 1950" is never one year — parents, spouses + marriage, children), People-tab profile (aliases, dates, notes, kinship rows), CyberBrain `toldItems` with their text (private items withheld) |
| `relatives` | `id`, `relation` = parents \| siblings \| spouses \| children \| grandparents \| greatgrandparents \| grandchildren \| all, `side` = maternal \| paternal | relatives with `path` and `source` (tree or People tab); `side` limits parents/grandparents/aunts-uncles, also for `relation=all` |
| `relationship_between` | `a`, `b` (ids), `max_generations` | relation of b to a, common ancestors, path ids; or `noPathWithinLimit` |
| `family_knowledge` | `query` (bare) and/or `id`, `limit` | told text: CyberBrain items + People-tab notes, with confidence and source |
| `search_media` | `people` (names or ids, comma = AND; matches person TAGS), `tags` (comma = AND; curated tags or person/family tags), `text` (words, all must match), `in` = filename,path,notes,place,transcript,captions, `place`, `years` (1984, 1980s, 1980-1989), `kind` = video (default) \| audio \| any, `people_basis` = confirmed \| detected (default) \| any, `include_mentions` (default true), `limit` | `matchCount` (distinct, copies collapsed), `recordCount`, `kindCounted` + `countBasis` (what was counted), `notCountedByKind` (e.g. audio-only files left out), items with `evidence`, `copies`; `mentions` = untagged files whose transcript/caption names the person (labelled, NOT counted); `textMatchesWithoutTag` = files matching the text but not the tag (check filenames) |
| `catalog_stats` | catalog: same filters as search_media (`kind` defaults to video) + `group_by` = decade \| year \| volume \| stream \| person. Tree: `surname`, `born_in` (place text; defaults to the owner's and spouse's ancestors), `scope` = family \| all \| ancestors:<id> \| descendants:<id>, `generations` | catalog: `totals` {distinctContent, records, extraCopies, distinctHours, allCopiesHours}, `countBasis`, `byStreamType`, `notCountedByKind`, per-group rows, `undatedExcluded`. Tree: `count` (primary name), `countIncludingAlternateNames`, `birthYearSpan`, `scope`, people (closest generations first) and a `truncationSummary` when cut |

Notes on the data: people tags are `confirmed` (by Rick), `detected` (face match)
or `suspected`; rejected tags are already removed. A media `year` comes from Rick's
date, an inferred range, a year in the filename, or a file stamp (`yearSource`); file
stamps are often transfer dates. Transcripts and captions are machine-made.

## How to answer

- Resolve every person first. No candidate → say the person isn't recorded and
  offer what you can do. Several → ask which one.
- Prefer "not recorded" over a guess. State the basis of every number.
- Label world/historical context as general knowledge, not family record.
- You cannot change any data. Never say you saved, edited or corrected anything.

## Runner contract (conversations)

`questions.json` holds `{"id", "category", "text"}` or `{"id", "category", "turns": [...]}`.
Answer a `turns` entry turn by turn, in order, keeping your own context between its
turns (pronouns refer back). Start each new entry with a clean context. For every
answer record: `id` (turn ids are `<id>-t1`, `-t2`, …), the answer prose, the ids
you cited, and the tool calls you made.

## Operator notes (not needed by the answering agent)

- Snapshots: `venv/bin/python scripts/hallie_demo/snapshot.py [--out DIR]`
  (text only: no pixels, audio, frames or face embeddings). Default `--out` is the
  session scratchpad; tools.py reads the same default or `--snapshots DIR`.
- Give the agent `questions.json`, this README and the tools. Never
  `hallie_baseline.json`, `tests/hallie_acceptance_v1.json` or the repo.
- Scoring: `scoring.md`. Frozen suite: `tests/hallie_acceptance_v1.json`,
  sha256 `ebd68308c852166227f2389f8987d1a5260f4eab9095e93573990bc047b1d2fc`.
  Its expected values were computed against catalog generation 3189 (saved
  2026-10-10T21:49:04Z) and tree gen-20260924T222812-b7d9; re-snapshotting a
  changed catalog moves the stats.
- Holdout: new live questions go in `tests/hallie_holdout.json`. Builders never
  tune against it.
- Tests: `venv/bin/python -m pytest tests/test_hallie_demo_tools.py -q`.
