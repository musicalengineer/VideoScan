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

### Afternoon, same day — the fallback shape again, six more times

| # | asked | what came back | root cause | status |
|---|-------|----------------|-----------|--------|
| 8 | "tell me about his parents" | repeated **Nathaniel's own bio** | pronoun resolved, RELATION dropped | **OPEN** |
| 9 | "tell me about the grandparents of X" | same, X's own bio | same | **OPEN** |
| 10 | "what country was John Hastings born in?" (×4) | his birth **date**, never the place | the place IS recorded — `2 PLAC Kenilworth, Warwickshire, England` — and the FT view shows it. Not missing data: the route answers a different field and never says it lacks one | **OPEN** |
| 11 | "what country?" (follow-up) | searched **videos** for the word "country" | a follow-up cannot inherit the previous route | **OPEN** |
| 12 | "tell me about stephen parker and stephen parker jr" | "which one do you mean?" | a deliberate TWO-PERSON ask read as ambiguity | **OPEN** |
| 13 | "Reading is pronounce Redding" | stored against **John Hastings 3rd Earl of Pembroke** | pronunciation filed under an unrelated person — data integrity, not phrasing | **OPEN** |

Row 10 is the one to look at first. It is not a decline-honesty gap, which is
what I assumed before checking the record properly: the field is present, the
inspector renders it, and the answer silently substitutes a different field.
Rick asked four times.

Row 13 is a different class from the rest and worth separating — nothing about
routing, a note written onto the wrong record.

### Late afternoon — the depth cap, and a pronunciation cluster

| # | asked | what came back | root cause | status |
|---|-------|----------------|-----------|--------|
| 14 | "how am I related to King Edward III of England?" | "no chain ... joins them within **12 steps**" | `relationshipSearchDepthLimit = 12`. Edward III is Rick's **18th-great-grandfather, 20 generations up**, on a 20-generation pull. Honest in form, but it reads as "not related" | **FIXED** — see below |
| 15 | "\"Edward III\" is pronounced Edward the third" | "I'll say **Edward as III** from now on" | the name/pronunciation pair was parsed backwards | **OPEN** |
| 16 | "III is Third" | searched **videos** for "iii", "third" | a bare pronunciation statement is not recognised; falls to catalog | **OPEN** |

Rows 13, 15 and 16 are one cluster: **pronunciation capture**. It files notes
against the wrong person, parses the pair backwards, and drops the bare form
into catalog search. Worth one pass over that path rather than three fixes.

Row 14 is worth recording carefully because the code was *not* wrong so much
as under-specified. Twelve hops is the right bound for **lateral** kin — six
up and six back down reaches a fifth cousin, and the prose grows with every
hop. A **direct ancestor** has no descent half: "your 18th-great-grandfather"
is four words however deep it runs. One constant was being asked to bound two
different shapes.

### The finding under all of it (2026-09-07 evening)

Rick asked five questions about one dead earl and got the same death sentence
to all of them — including "whom did he marry" and "tell me all about Edward
III". Minutes later "his spouse?" answered correctly.

**The prose is not in this codebase.** The wording changed every time — "has
passed away", "has passed on", "is no longer with us" — because the MODEL was
composing it. After a long run of turns about a deceased person it settles on
`operation: death` and answers everything that way, and nothing deterministic
disagreed.

That is the same shape as every other row here, one layer up: **the model is
being asked to make a judgement the sentence already settles.** Which field a
question wants — place, relation, whole person — is not a judgement call. It
is in the words.

So three guards now run after the model and before the executor, narrowest
first:

| the sentence says | the operation becomes |
|---|---|
| "where / what country / birthplace" | `birthPlace` (or `deathPlace` — the sentence's OWN death cue decides, never the model's) |
| exactly one relation — "marry", "his parents", "the grandparents of X" | `kinship` with that relation |
| "tell me about / who is / describe X" | `biography` |

Each is skipped when the sentence is ambiguous — two relations named, or
none — so the model keeps every question that genuinely needs judgement.

A correction I made inside the correction: the first version of the place
guard took the model's word for birth-vs-death, so "what country was John
Hastings **born** in?" arriving as `death` produced a death answer. Rick found
it within minutes of it shipping. The sentence decides now.

### The worst one, found last (2026-09-07 evening)

  Q: how are we related, if at all, to king henry the 8th?
  A: Philippa de Hainaut Queen of England is Richard Harding Breen Jr's
     18th-great-grandmother. Line: Richard Harding Breen Jr → ...

**Henry VIII is not in either tree.** The only matches are people whose notes
mention him — "John Alexander Harrington (confidant of Henry VIII)", "Sir
Robert Browne ** Privey Chamber to Henry VIII". The correct answer was that he
is absent, and it could have added that three people in the tree are recorded
around his court, which is a better answer than the one given.

Instead the subject from the PREVIOUS turn leaked forward when the named
person failed to resolve.

This is the nastiest form of the day's pattern, and worth keeping at the top
of this file for that reason: **the answer is TRUE.** Philippa really is his
18th-great-grandmother; the chain is real and checkable. Nothing about it
reads as an error unless the reader notices it is about a person they did not
ask about. Rick asked "if at all" — he was explicitly open to "not related",
and got a confident answer about someone else.

Rick re-asked with both full names and got a different wrong answer:

  Q: how is richard h breen jr related to king henry 8th?
  A: I wasn't sure which person you meant — richard h breen jr or king
     henry 8th? Ask about one of them and I'll look them up.

Better — it declines rather than leaking — but it is the wrong decline, and
the shape is this morning's `["my dad", "dad"]` bug again: TWO PEOPLE IN A
RELATIONSHIP QUESTION read as two candidates for one slot. Henry VIII fails to
resolve, and a MISSING person is reported as an AMBIGUOUS one, which sends
Rick off to disambiguate between a person who exists and a person who does
not.

Two rules, then, not one:
  * an unresolved subject must never silently inherit the previous one;
  * when one of two named people cannot be found, say WHICH — "Henry VIII is
    not in this tree" — rather than asking which of them was meant.

The rule it argues for: **an unresolved subject must never silently inherit
the previous one.** A named person who cannot be found is a decline, always,
and "not in the tree" is a real answer that this tree can support.

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

**DONE 2026-09-07:** rows 4 and 5 — `c54e5c4c`. The trail cue recognised
essentially one sentence (the demo's): every line noun was singular so
"maternal lineS" missed, "tree" was not a line noun, and a bare "my line"
named no side so the gate refused and the turn fell to the country route.
Plural nouns, a bare line of descent meaning every ancestor, edit-distance-1
typo tolerance, and a continent backstop that resolves by membership instead
of a country token. 33 tests.

**DONE 2026-09-07:** row 14 — a direct-line search (`directLineSearchDepthLimit
= 25`, parent edges only) runs before the decline, so a straight climb is found
and named with its chain. The twelve-hop lateral bound is untouched, and a test
asserts that. 5 Core tests.

Rows 1, 2, 3 and 6, the afternoon batch, and the pronunciation cluster
(13, 15, 16): **OPEN, none started.**

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
