# Hallie — live failure ledger

Every miss Rick hits in a real session, with what actually happened and where
it lives in the code. Started 2026-09-07 at Rick's request ("keep track of
these failures").

**How this is kept.** Turns are harvested into `tests/hallie_eval_corpus.json`
by `scripts/hallie_harvest_queries.py` every session; this file is the
readable index over them, because a 322-entry JSON is not something anyone
reads. Every row carries its corpus id. A row leaves OPEN only when a
regression test pins the fixed behaviour.

---

## The shape behind most of them

Four of the seven turns below are the same defect at different depths:

> **A cue misses, and the fallback answers a *different* question with full
> confidence instead of saying it did not understand.**

Every one of those four answers was *true* and *cited*. None was the question
asked. This matters more than any single row: a wrong-but-confident answer
about your own family is worse than a decline, and Rick cannot tell the two
apart from the outside.

---

## 2026-09-07

| # | id | asked | what came back | root cause | status |
|---|----|-------|----------------|-----------|--------|
| 1 | `lv260907-002` | "in the family tree going back, find the highest level of royalty or title such as lord, prince, king, etc." | Searched **video filenames** for "royalty", "title", "king" — "found nothing in the catalog" | No title/keyword search on the tree route; question routed to catalog | **OPEN** — [design](hallie_titled_ancestors_design.md) |
| 2 | `lv260907-003` | "not in videos, in family tree" | "I can't refine my last answer that way — I can only drop a person, not a topic word" | Refinement path cannot change **route** | **OPEN** |
| 3 | `lv260907-004` | "search the family tree for a title like king" | Read **"Title like king" as a person's name**, offered to remember it | Same as #1; bare text fell to the name resolver | **OPEN** |
| 4 | `lv260907-005` | "find the birthplaces of my **materanl** lines back to europe" | "Richard Harding Breen Jr was born 4 March 1959." | One transposed character. `HallieBirthplaceTrail.swift:69` gates on the literal token `maternal`; no cue → generic birth route | **OPEN** |
| 5 | `lv260907-006` | "trace my line back to europe" | "the tree records nobody born in Europe. The places it does reach: the United States, Canada, **Ireland, the United Kingdom**…" | `HallieLineageQuestion.swift:262` captures whatever follows "back to" as a **country**, so `country="Europe"` matched nothing. Classifier (`BirthplaceClassifier.swift:250-253`) and the `.continent(.europe)` stop are both correct — this route never reaches them | **OPEN** |
| 6 | `lv260907-007` | "Ireland and the UK are part of europe aren't they?" | **Rick's own biography** | No route matched a general-knowledge geography question; fell to the owner/biography route | **OPEN** |
| 7 | `lv260907-001` | "find the most recent common ancestor between rick breen and donna breen" | (answered) | — | expectation unconfirmed |

### Proposed fixes, smallest first

1. **Continent destinations reach the continent stop** — match the captured
   destination against `BirthplaceClassifier.Continent` rawValues before
   treating it as a country. Fixes #5.
2. **An unrecognised destination is said out loud** — never "nobody born in X"
   for an X we do not recognise as a place. Kills the whole phantom-country
   class ("back to the old country", "back to Ulster"). Same function as 1.
3. **Fuzzy cue matching** — edit-distance-1 on the line words only, so
   `materanl` does not silently change routes. Fixes #4. Rick's standing note
   is "tolerate typos".
4. **Ad-hoc tree text search** — `index.sidebarRows(containing:)`
   (`Index.swift:607`), per codex #1161/#1162. Fixes #1 and #3.
5. **Route-changing refinements** — #2, largest, wants design.

Awaiting Rick on order; none started.

---

## Not a Hallie answer, but found the same day

| what | where | status |
|------|-------|--------|
| A failed profile save shows **no error at all** and loses the draft — `attemptSave` dismisses unconditionally whether the save worked or not | `PersonEditSheet.attemptSave:267-268`; warning renders against `displayedProfiles` (`PersonFinderView+People.swift:270`) so a failed rename or add has no card | **OPEN** — codex #1164/#1165 |

---

## Tooling that hid failures (fixed 2026-09-07)

Each of these meant a real failure went unrecorded or unreviewed. They are
listed because the pattern is the point: the instruments were failing the same
way the product was — quietly.

| what was wrong | effect | fix |
|----------------|--------|-----|
| Nightly test verdict ignored a nonzero exit code | A crashing host published **status=ok, 6830 passed, 0 failed** | `1701bdcf` |
| Nightly reviewer followed `origin/main` | 33 commits unreviewed over two nights while main sat unpushed | `31ad6aea` |
| Errored reviews advanced the baseline anyway | 19 of the first 122 commits never read by anything, ever | `31ad6aea` |
| Reviewer output directory was per-minute | A clean retry inherited the previous run's stale ERROR verdicts | `1be06c54` |
| Harvester tested only the first word of a line | "in the family tree going back, find…" dropped; the same question asked plainly kept | `1563f99f` |
| Harvester dropped corrections | "not in videos, in family tree" — the most interesting turn of the morning — never recorded | `1563f99f` |
| Harvester wrote `indent=2` into an `indent=1` corpus | Every harvest was a 5,160-line diff; nothing in it could be reviewed | `1563f99f` |
| Harvester did not know `trace` | "trace my line back to europe" never recorded | `be0dd162` |
| Harvester ids restarted each run | Two different questions shared `lv260907-001` | `be0dd162` |
