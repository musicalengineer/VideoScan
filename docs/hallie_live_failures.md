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
| 1 | `lv260907-002` | "in the family tree going back, find the highest level of royalty or title such as lord, prince, king, etc." | Searched **video filenames** for "royalty", "title", "king" — "found nothing in the catalog" | No title/keyword search on the tree route; question routed to catalog | **OPEN** — [design](hallie.md) |
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

### Evening, 09/07 — a media ask lost to identity binding

| # | asked | what came back | root cause | status |
|---|-------|----------------|-----------|--------|
| 17 | "find videos with dad" | "I took 'dad' to mean Richard. I don't have any videos tagged with Richard yet." | The People-tab binding correctly resolved "dad" → Richard, then the catalog was searched for the ONE bound spelling. The catalog tags carry the aliases ("Dad", "Richard Breen Sr"); a resolved identity must search by all of its names, not by whichever one won the binding. Rank-1 boundary (codex #1182). | **FIXED** 09/07 late: `ArchivistPresenceQuery.Identity` carries the profile's other spellings; a spelling any OTHER profile answers to is never widened (brother Tim / son Timmy). `HalliePresenceAliasSearchTests`; `b7f5ec39` |

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

### Late evening, 09/07 — what the first strict replay found (fixed, pending checkpoint)

| # | asked | what came back | root cause | status |
|---|-------|----------------|-----------|--------|
| 18 | "what country was John Hastings born in?" (strict-001, live binary) | the birth **date** — an hour after the place guard shipped | the question was never passed into `ArchivistGraphQuery` on the single-person path; the guards only ran for relationship questions. The unit tests called the initializer directly and were green | **FIXED** (question threaded at both sites) |
| 19 | "what country?" after 18 | **Rick's biography** | `isKnownPerson("country")` is TRUE on the tree — the loose matcher resolves it to "William Culpeper of Preston Hall"; "born" and "he" resolve to narrative NAME records. The follow-up resolver name-probed every word and saw a fresh question | **FIXED** (resolver never probes its own vocabulary); structural cause OPEN — see decisions |
| 20 | "tell me about dad" (strict-011) | "Richard Harding Breen Sr's **father** was George Breen" | the relation guard read the subject's own word ("dad", person=dad) as a relation asked of him | **FIXED** (guard ignores the subject's words) |
| 21 | any translated question, 21:22 onward | `presence` / `event` / `temporal` shapes for graph questions | **the brain**: byte-identical requests to ricksm5 answered differently at temperature 0 (18 samples of one question → 5 shapes). ollama serve 0.32.14 under a 0.33.3 runner, 972 MB free | **OPEN — Rick** (restart ollama on M5) |

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
| `queryDescription` named the model's operation, not the resolved one | strict-001 answered correctly and was flagged `query_description_mismatch`; a log reader could not see a guard fire | `graphQueryDescription(_:resolved:)` |
| Unit tests exercised the guard function, not the executor path | the place guard was green for an hour while the live path never called it | strict lane (`tests/hallie_strict_regressions.json`) |

---

## Mode routing, 2026-09-17 (codex advisory 399 + strict 44)

Observed in `[hallie-mode]` over ~400 turns. The run itself is
**data-compromised** for tree content — the compiled pointer was on a
test-polluted single-source generation — so answer quality is not graded
here. Routing is independent of tree content, so these stand.

### CONFIRMED in source

| what | where | effect |
|------|-------|--------|
| `is`/`are`/`was`/`were` are in **both** `filler` (no content) and `sentenceVerbs` (proof of a standalone sentence). The `sentenceVerbs` early-return fires *before* the content-word count, so a copula alone defeats stickiness. | `HallieModeClassifier.isElliptical:287-300` | "when was this filmed" (content words: `filmed`), "how old is this tape" (`old, tape`), "which one is the oldest", "how old was Timmy in this" → all `unknown`. "and the youngest?" survives on the lead rule, "when did she die" on the pronoun rule. |
| `this`/`that`/`it` are in `filler` and `demonstratives` but **not** in `pronouns` (= `HalliePronounContinuity.singular ∪ .plural`, which is he/she only). | `HallieModeClassifier:154-160` | Deictic reference to the selected item has no continuity path at all. Clicking a video and asking about it is the app's most natural gesture. |
| Cues match as bare substrings with no syntactic role. | `catalogCues` / `treeCues` | "what invention had the biggest impact on your life" → **catalog** on `biggest`; "how much did things cost when you were a kid" → **tree** on `kid`; "did you ever get in trouble as a kid" → **tree**. Confident wrong answers, the class this ledger exists for. |
| Sticky carries the previous mode into a turn that names a new subject *and* the other mode. | step 5, after cues | "show thankful pratt tree" → `mode=catalog reason=sticky` → `declined: catalog refused shape=graph`. The user typed "tree" and got a refusal. |

### Observed, not yet traced

- Kin term + media noun = `conflict` → `unknown`: "show me videos of my dad",
  "find videos of my brother tim", "do we have any video of my father talking
  about typewriters". The last is close to the reason the archive exists.
- `rewrite:` reassigns the subject to the speaker: *read "who was my father as
  a young man" as a family-tree question about **me***.
- Tree mode has no `event` shape: "tell me about the move to the Berkshires"
  and "what stories do we have about the World War Two generation" both
  `declined: tree refused shape=event (unsupported)`.
- A common noun reached the people slot and the strict validator caught it:
  `anchorPeople: ["footage"]` for "how many years of footage do we have"
  (`NLTranslatorError.badResponse`). The validator did its job.

Interview-mode and composition turns ("what was your first job", "write
something about Donna I could read out loud at a family gathering") route to
`unknown` because they are **not built**, not because routing failed. Not
defects; they are the interview/composition backlog.

### Kin-term conflict — root cause, and one open design question (2026-09-17)

`treeCues` contains `dad`, `father`, `brother`, `wedding`, `family`;
`catalogCues` contains `video`, `videos`, `footage`. A sentence with one of
each sets `conflicted` and returns `unknown`. That is why Rick's own spot
test produced:

| asked | routed |
|---|---|
| `show videos of tim` | catalog ✓ |
| `find videos of my brother tim` | **conflict** |

Same person, same intent. "my brother" breaks a query that works without it.

**The rule already exists in the codebase.** `HallieMediaVocabulary`
`.containsItemNoun` documents itself as *"the reading under which a tree
person plus a media noun is a catalog search ('videos of nathaniel
parker')"*, and step 4 of the classifier applies exactly that — but only
when `subjectPhrase` resolves to a proper name the oracle knows. A person
named by kinship never reaches it. `photoNouns` are deliberately excluded
(a photo of a tree person is the portrait road, a TREE answer), so any fix
must use `containsItemNoun`, not `containsMediaWord`.

Extending the rule to the conflict branch fixes every retrieval ask Rick
hit: "show me videos of my dad", "any videos of the kids at Christmas",
"can you show me the wedding video", "do we have any video of my father
talking about typewriters", "find videos of my brother tim".

**OPEN — do not land without a ruling.** It also catches
`"how old would my dad have been in this video"`, which is not a retrieval
ask at all: it needs the video's date AND a birth year, i.e. both modes.
Routing it to catalog would answer a different question **confidently**,
which this ledger already records as the worst failure mode. `unknown` is
wrong but honest; catalog is wrong and assured. Splitting retrieval asks
from fact-questions-that-mention-a-video means either another heuristic
layer on a module that is already failing from heuristic collisions, or
the two-mode answer: let a turn consult both.

### 2026-09-17 overnight: a hidden person leaves their FAMILY records behind

Found by the overnight run (328/399 vs the 12:03 baseline's 320 — net churn,
**not** an improvement claim: 30 newly flagged, 38 newly clean). Inside that
churn was one cluster that is not noise: four consecutive Eileen Latta
questions newly failing.

```
who is eileen latta's mother                          missing_required_text
tell me about eileen latta                            missing_required_text
who are eileen's parents                              missing_required_text
show eileen latta's maternal line back 3 generations  missing_required_text
```

**Cause.** Mary Christina O'Connor being in FamilySearch twice propagates
into FAMILY records. Eileen now has THREE parent families, all one marriage:

| family | husband | wife |
|---|---|---|
| `@F3@` | David McGill Latta Sr | Mary Christina O'Connor `G89Q-34N` |
| `@F4@` | — | Mary O'Connor `GNZ5-428` ← the duplicate |
| `@FB3@` | — | Mary Christina O'Connor `G89Q-34N` |

The refreshed pull ADDED `@FB3@`, which is why this appeared tonight and not
this morning — the old tree had two, the corrected tree has three.

**The gap.** Hiding the duplicate PERSON does not disregard the family whose
only parent is that person. Suppression is per-person; `@F4@` survives and
keeps Eileen attached to it.

**Not fixed, deliberately.** The repair is in parent-family resolution, which
decides who Rick's relatives' parents are. His 2026-09-02 ruling governs the
two-FAMC case ("a family FamilySearch itself knows outranks a stray local
one"); three links where two name the same woman under different ids is the
case that ruling did not consider, and it is his call. Pinned as a
`withKnownIssue` in `HiddenPersonLeavesFamilyRecordsBehindTests` so it cannot
rot and fails loudly the day it is fixed.

---

## 2026-09-20 — "Event queries are not supported yet" (fixed same evening)

Rick, evening: *"getting a lot of these: 'Event queries are not supported yet;
I did not run a broader search.'"* From `hallie-conversation-2026-09-20.jsonl`
and `-21.jsonl` (one session, six turns):

| # | asked | mode | what came back | route |
|---|-------|------|----------------|-------|
| 1 | "show me videos of donna down the cape in the 90s" | tree | "Event queries are not supported yet; I did not run a broader search." | `unsupported-event` |
| 2 | "show me Donna down the cape in the early 90s" | unknown | same | `unsupported-event` |
| 3 | "show me Donna down the cape in the early 90s" | unknown | same | `unsupported-event` |
| 4 | "show me Donna down the cape in the early 90s" | unknown | same | `unsupported-event` |
| 5 | "show me videos of donna down the cape" | tree | same | `unsupported-event` |
| 6 | "show me ellen ronan" | catalog | same | `unsupported-event` |

Beside them, in the same session: "hi hallie tell me about donna" and "can I
give you a research note about Ellen Ronan?" → `[hallie-mode] declined: mode
gate: tree refused shape=event (unsupported)`.

These are the app's core catalog questions — person + place + era, the
search-first north star — and every one was refused.

**Cause (two, both in source).**

1. `HallieTurnExecutor.route(.event)` returned `.unsupportedEvent`, and
   `execute` answered every event with a hard-coded refusal in every mode.
   Yet `ArchivistQueryAST.Event` carries exactly the fields `Cross` does
   (people, years, media kind, keywords, transcript), and `cross` has run
   on the presence executor since 2026-08-17. The local translator
   over-applies its prompt rule *"event: what happened at an event"* to any
   "show me X at Y in the 90s", so the refusal fired on ordinary asks.
2. `HallieModeGate.reconcileTree` recognised catalog intent by media
   **noun** only. "show me Donna down the cape in the early 90s" has none,
   so under the tree it became a biography rewrite; an `event` AST with no
   single person was refused as `tree refused shape=event`.

**Fix (branch `fix/hallie-event-shape-fallback`).**

- `HallieTurnExecutor+Event.swift`: `.event` → `executeEvent`, which builds
  the presence query (keywords + transcript terms merged, blanks dropped) and
  runs `executePresenceLike` with route `.event` — same hits, citations,
  offered actions and relaxed facets as the presence AST built by hand. Basis:
  *"read as an event question; searched the catalog for donna with “cape” in
  1990–1999"*. Only an event with no people, no words and no years declines,
  and that one asks *"Who or what should I look for, and roughly when?"*.
  `Route.unsupportedEvent` is gone; `.event` is a catalog route for memory,
  the answer plan, provenance, paging and snapshot capture.
- `HallieModeGate`: new outcome `.switchToCatalog(note:)`. In tree mode a
  catalog-shaped AST switches when the sentence has a media noun / collection
  word, **or** a retrieval verb (show, find, play, watch, count, list, search,
  pull, look, browse) with no tree word or phrase in it. The coordinator and
  the shell run the turn with `context.mode = .catalog` and log
  `[hallie-mode] switched tree→catalog for shape=<presence|cross|event>`.
  "show me ellen ronan in the family tree", "show me rick's parents" and
  "any pictures of donna" keep their tree roads.
- `OllamaQueryTranslator.astSystemPrompt`: event is ONLY "what happened
  at/when …"; one presence example for the cape sentence. A courtesy — the
  executor no longer depends on the translator getting this right.

**Pinned.** `HallieEventShapeFallbackTests` (the six turns as event ASTs
against a fixture catalog: same citations as presence, basis prefix, never
"not supported"; empty event asks for specifics; memory/plan/provenance treat
event as catalog) and `HallieEventShapeModeGateTests` (pinned tree mode +
"show me videos of donna down the cape" → executed in catalog mode + the
switch line; the presence-shape variant; "in the family tree" never
switches). `HallieModeGateTests` gained the retrieval-verb cases.

## 2026-09-21 — "how old was dad breen when he passed?" → a biography of Matthew Rice (b. 1629)

Rick, 13:52, tree mode (`[hallie-mode] mode=tree reason=explicitCue(dad)`).
The transcript row: `shape=graph operation=biography person=Matthew Rice` —
*"Matthew Rice was born 28 February 1629 in Great Berkhampstead … died before
29 November 1717 in Sudbury"*. The app log says `phrased temporal/answered by
model`. Rick: *"make a note when hallie fails such as just now … Imagine when
we turn her loose on real family, what will she fail at."*

**What the right answer is.** "Dad Breen" is an ALIAS on the People tab
(Richard Breen, b. 21 Feb 1929, d. 25 Jun 2008 — the People tab is the
source of truth for the inner circle): **79** when he died, on 25 June 2008.
There are two Richard Breens on the People tab (Dad and Rick); the alias is
what disambiguates, and a kin term + surname ("dad breen", "ma breen",
"gramma breen") must resolve to the alias BEFORE any tree-wide name scan.

**Failure class.** The worst one: a confident, fully-cited answer about the
WRONG PERSON — not a decline, not a clarify. A cousin would not know Matthew
Rice is nobody's dad. Same family as the 9/07 ledger finding ("fallback
answers a DIFFERENT question confidently") and the 9/17 kin-term collision.

**Not yet traced** (bug-fix lane `fix/hallie-dad-breen-age-at-death`):
why "dad breen" reached the graph as a person named something else — alias
lookup missed on the two-word alias with a surname? the age-at-death
temporal shape has no executor and fell through to a biography of the
translator's guess? Trace, fix, pin, then add `strict-045`.

**Variations to cover** (advisory corpus, `lv260921-*`): "how old was Dad
when he died", "what age did Ma Breen pass", "how old was my dad breen when
he passed", "when did dad breen die", "how old would Dad Breen be today",
"how old was Ma when Dad died", "how long did Ma outlive Dad", "how old was
Rick when his father died" — every kin term × every inner-circle alias × the
age/when/how-long shapes.

Also in the same ten minutes (not failures, but corpus fodder): "how am I
related to edward iii of england?", "who in the family was in the us marine
corps?", "The US Marine Corps" (a bare topic follow-up, sent to the general
lane), "tell me about rick" / "tell me about dicky" (template on model
timeout — codex's replay had the M4 brain busy).

## 2026-09-21 — codex's visible replay on 9818ff51 vs the 09-18 baseline (93b97f2f)

| run | strict (44) | advisory (412) |
|-----|-------------|----------------|
| 09-18 nightly | 41 clean / 3 defects | 343 clean / 56 defects |
| 09-21 live (codex, M4) | 40 / 4 | 329 / 83 — **32 new defects, 7 fixed** |

The 32 new ones fall into three clusters, each with a lane:

1. **Renamed people lost their videos** (9): "show videos of tim" → *"I took
   “tim” to mean Timothy. I don't have any videos tagged with Timothy yet"*;
   "how many videos of my dad" → *"…tagged with Richard Harding Breen Sr"*.
   Catalog tags are strings captured when tagged ("Tim", "Timmy"); on 9/19–20
   the People profiles were renamed (Timothy Christopher Breen / Timothy
   William Breen / Daniel / Elizabeth / Richard) and the presence executor
   matches tags by the profile's `name`. Rick hit it live at 13:54. Lane
   `fix/hallie-dad-breen-age-at-death` (same resolution code). Long-term:
   tags keyed by POI UUID.
2. **Social / identity turns became catalog searches** (9): "nice to meet
   you" → 51 transcript hits; "that was terrible lol" → event → Christmas
   files; "ok" → 960 videos. Lane `fix/hallie-social-and-family-wide`.
3. **Family-wide tree questions decline "couldn't tell who it is about"**
   (6): "how many grandchildren are there", "list everyone in the family",
   "what do you know about the Breen family". Same lane.

Plus the wrong-person miss above (not in the corpus until today).
