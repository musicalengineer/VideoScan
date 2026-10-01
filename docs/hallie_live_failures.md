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

**Traced (2026-09-21, lane `fix/hallie-dad-breen-age-at-death`).** The
Matthew Rice row was NOT Rick's turn: the transcript file is shared, and
row 813 (`1603DC26`, `client=shell`, "tell me about Matthew Rice") is
codex's replay interleaved between Rick's question (row 812, `7B52B1A4`,
`client=app`) and Rick's answer (row 816). What Rick actually heard, 7.3 s
of audio: *"Richard was 64–65 years old during 1994, depending on the
date"* — `route=temporal shape=temporal operation=age subject=dad breen`,
basis *"the question supplied year 1994 without a month/day"*. The alias
"Dad Breen" DID resolve to Richard Breen Sr. Two defects, both in the
temporal lane: (1) there was no age-at-death ask — "when he passed" was
read as a plain age needing a reference date; (2) the translator invented
`explicitYear(1994)` (the question has no year) and the executor trusted
it. Fixed: `ArchivistTemporalExecutor.Ask.ageAtDeath` + `GroupReference
.death` count from the person's own People-profile dates ("Richard was 79
when he passed on, on 25 June 2008"); `questionSuppliesYear` drops a year
the question never said and says so in the basis; a bare "dad" subject in
Rick's session binds like "my dad"; "how old would X be today" counts to
today and says he passed. Also found on the way (same lane): the
transcript recorded `mode=catalog` for the turn because a temporal
result carried no mode and memory derived it from the route — the gate
had KEPT tree mode; the answer now says `.tree`. Pinned by
`HallieDadBreenAgeAtDeathTests`; strict-045.

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

### Same day, 13:54 — "find videos of tim" → "I took “tim” to mean Timothy. I don't have any videos tagged with Timothy yet."

Nine replay misses since 2026-09-18 of the same shape (cs029, tm002,
ft013, lv260901-001, lv260906-002, lv260902-023, ft005; "my dad" → *"tagged
with Richard Harding Breen Sr"* in cc015, cs023). Cause: on 2026-09-19/20
Rick renamed his People profiles to legal given names — two profiles are
now NAMED "Timothy" (aliases Tim / Timmy) and Dad is "Richard" (alias
"Dad Breen") — while catalog person tags are the plain strings captured
when the video was tagged (live catalog.json: Dad 10, Tim 6, Timmy 2).
Traced to three places: `recoverPresencePeople` rewrote "tim" to the
shared canonical "Timothy", so `presenceAliases` (keyed by that string)
saw two profiles and gave up; `presenceAliases` matched only names and
aliases, never full-name forms, so the bound "Richard Harding Breen Sr"
had no alias set; and `FamilyKinshipOverlay.nodes(claiming:)` returned
BOTH Richards for the owner "Rick Breen" — `PersonResolver` identifies a
person by canonical-name STRING, so "Rick Breen" resolves to "Richard",
which is two nodes — and the People-tab path for "my dad" was skipped for
the tree. Fixed additively (`knownSpellings(of:)`: name + aliases +
full-name forms + the bare kin word of a "Dad Breen" alias + the pinned
tree name; the typed alias stays the search identity when the canonical
is shared; the overlay narrows same-canonical nodes by the typed exact
spelling). Pinned by `HalliePresenceRenamedProfileTagsTests`. The proper
fix — tags keyed by POI UUID — is a separate job; until then two
profiles with the same canonical name are one identity to
`PersonResolver` everywhere it is used.

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

Correction to the wrong-person entry above: the Matthew Rice row was codex's replay turn interleaved in the shared transcript. Rick's own answer was "Richard was 64–65 years old during 1994" — right person, invented year. Fixed on the same branch (age-at-death from People-tab dates; the translator's invented year no longer trusted); strict-045.

## 2026-09-25 → 26 night — regression check (branch `fix/hallie-night-0925`)

**Brain:** `qwen3.8:27b-mlx` (digest `5642e97495e1`), M4 loopback ollama **0.34.4**,
headless read-only shell (`scripts/hallie --no-actions`, no UI automation).
**The 09-18 baseline ran on ollama 0.34.0.** Ollama auto-updated to 0.34.2
(09-22) and 0.34.4 (09-24) with the same model weights; the translator now
mis-slots facets it used to fill (a place in the people slot, a stated year
left out, a media ask read as an age question). That is the drift behind most
of the advisory losses below — not a code change. Run-to-run variance on the
advisory lane is about ±30 flips each way.

**Harvest:** 11 new live turns 2026-09-21…24 (`lv260925-001…011`), five of
them live misses, annotated in the corpus.

| run | strict | advisory (all) | advisory on 09-18's 399 |
|-----|--------|----------------|-------------------------|
| 09-18 nightly (baseline, 93b97f2f, ollama 0.34.0) | 41 / 44 | 343 / 399 | 343 |
| 09-25 03:04 nightly (44708097) | 23 / 52 | 443 / 739 | — (no tree loaded, see below) |
| tonight, main `0e021ea6` (clean) | 48 / 55 · **46 / 52** on the pre-existing entries | 598 / 750 | 332 |
| tonight, branch `47bc3d3c` (clean) | **51 / 55** · 48 / 52 on the pre-existing entries | **608 / 750** | 335 |

Not measurements: a first pass at 20:50 shared the M4's brain with a
model-fitness review lane (`review_real_commits.py`, 8-minute generations);
every Hallie `/api/chat` timed out at 6 s / 21 s ("I'm having trouble reaching
my language helper"), 5 strict turns failed that way and the advisory lane
finished 249 of 750. **Hallie replays and model reviews must not share the M4
brain.**

**Why the 09-23…25 nightlies read 16–23 strict:** the replay found no tree
("I don't have an imported family tree") — the 09-24 codec bump and the
recovery-floor bug fixed on main in 6160e837. Tonight's main binary loads it.

### Fixed tonight (red test first, then the fix; ricksm5, Debug, suite-filtered)

| # | live / replay | cause | fix | pinned by |
|---|---------------|-------|-----|-----------|
| 1 | "Christmas videos from 2006" (live 09-22, 09-24, **09-25 20:33**) → "There are 864 catalog items from 2006" | translator returned `year=2006`, Christmas dropped | `HallieDroppedTopicWord`: a curated `ArchivistKeywordAliases` word the question says and no AST term covers is put back; basis names it (`HallieTurnExecutor+Presence.swift` `restoreDroppedTopicWords`) | `HallieDroppedTopicWordTests`; strict-053 |
| 2 | "tell me about thankful pratt and her husband" after a Timmy answer (live 09-23) → "thankful pratt or timmy?" | `HalliePronounContinuity.rewrite` bound "her" to the last answer's person | a known person named earlier in the sentence is the antecedent; the pronoun is bound to that name | `HalliePronounInSentenceAntecedentTests`; strict-054/055 |
| 3 | "tell me about ellen" (live 09-21, still so on main) → "Which ellen do you mean: Ellen Ronan, Ellen Ronan?" | CyberBrain matched one WORD of two Ellen Ronan records and pre-empted the People tab's exact "Ellen" (his sister) | a token-only CyberBrain match yields to an exact People-tab claim (`HallieTurnExecutor.swift` `executeCyberBrainBiography`) | `HallieCyberBrainTokenMatchVsPeopleTabTests` |
| 4 | strict-009 "…my materanl lines back to europe" (green 09-18/21) → catalog search | typo front door rewrote "lines" → "line's" (Line is a tree name), hiding the line noun from the materanl repair | a real English word is never a possessive of a tree-only name (`HallieTypoNormalizer.possessive`) | `HallieTypoPossessiveRealWordTests` |
| 5 | "how old was dad in 1985" ×13 (var-age) → "give me a year" | translator dropped the year (`reference=currentSelection`) | the one stated four-digit year becomes the reference; basis says so (`ArchivistTemporalExecutor.statedYear`) | `HallieDadBreenAgeAtDeathTests` (+2) |
| 6 | "find donna down the cape in the 90s" ×5 live asks → "no videos tagged with Donna and cape" | translator put `cape` in the people slot; the tree's Cape family kept it a person | a curated place/occasion word in the people slot is searched as a word unless inner circle (`demoteTopicPeople`) | `HallieDroppedTopicWordTests` |
| 7 | "Christmas videos from 2006" as `shape=temporal` (live 09-24, branch replay) → "I need a dated video" | translator read a media ask as an age question | a fresh temporal turn with a media noun and no age word runs its presence search (`mediaAskMisreadAsAge`) | `HallieDroppedTopicWordTests` |

Manifest: strict-052 `expect` biography → graceful_decline (its honest decline
graded as a defect every night since 09-23; the note already said outcome
unconstrained). Suites: 2,333 Swift Testing tests in 276 suites (every
Hallie*/Archivist*/PeopleTab*/CyberBrain*/Person* suite) + 7 XCTest, green, 1
known issue (#567); pytest 75 passed.

Cape asks 8 → 14 of 16 clean; var-age 42 → 50 of 72.

### Still open

- **strict-036** "show me", **strict-042** "why do you ask me for a photo of Thankful Pratt…", **strict-044** "Beth Breen Beth McAuliffe" — red since the 09-18 baseline.
- **strict-048** "tell me about John Robert Latta": the MODEL-composed answer drops Rick's Fort Wagner note (the template kept it on 09-25 03:04). The composition verifier does not require every planned claim to survive phrasing.
- **"Ellen Ronan"** — two CyberBrain records for Rick's great-grandmother (`person.ellen-ronan.i342486919798`, pointer `@I342486919798@` not in the current tree, and `person.ellen-ronan.i10`); the which-one shows two identical names and a raw id. Data, needs Rick's ruling on merging them.
- **"Did you mean Richard or Richard?"** (strict-026, graded clean) — two same-name candidates, no qualifier.
- A People profile marked notInFamilyTree is still bound to a lone tree namesake by given name (seen in a fixture: "Ellen Ronan (Ellen in the People tab)").
- lv260925-008 in the advisory run: the bound "thankful pratt's husband" was read as a name; strict-055 (same words) answered "Nathaniel Caleb Parker". Translator variance.
- The advisory drift on 09-18's 399 (343 → 335) tracks the ollama 0.34.0 → 0.34.4 update; social/identity turns becoming catalog searches ("who made you" → 10,506 items) are the largest remaining group.

## 2026-09-26 — "find videos of dad" → Dafydd ab Einion (b. ~1360), twice, and the tree opened on him after Rick said no

Rick, 14:14–14:17 ET (session `627FCBEB`, app; the transcript's `Z` stamps are
UTC). Corpus `lv260926-001…004`; strict `strict-056…059`; branch
`fix/hallie-dad-dafydd`.

| # | id | asked | what came back | status |
|---|----|-------|----------------|--------|
| 1 | `lv260926-001` | "find videos of dad" | *"Dafydd ab Einion "Y Giwn Llwyd" was born about 1360, more than five centuries before motion pictures begin in 1888 — no one lives that long, so there can’t be film of him."* route=graph, no search run | **FIXED** (A) |
| 2 | `lv260926-002` | "dad breen not someone from 5 centuries ago" | Richard Harding Breen Sr's biography (right) — **and** a second bubble in the same second: *"Opening the Family Tree tab focused on Dafydd ab Einion."* | **FIXED** (C) |
| 3 | `lv260926-003` | "sure" | Richard Sr's Marine Corps service; "I have 4 photos of him — want to see them all?" | fine |
| 4 | `lv260926-004` | "sure, but I also want videos of dad" | Dafydd ab Einion, word for word, again | **FIXED** (A + B) |

**Failure class.** The 9/07 shape once more — a confident, cited answer about
the WRONG PERSON — and this time the wrong person was one Rick had just
rejected in so many words. Row 2 is the worst of it: the app *acted* on the
rejected person after the correction.

### A. "dad" was never fuzzy-matched. The tree has a man named Dad.

`docs/hallie_live_failures.md` and the 9/11 strict notes both say "fuzzy-
matched 'dad' to Dafydd". It is not fuzzy. The merged FamilySearch tree's
`@IB21341@` — Dafydd ab Einion "Y Giwn Llwyd", b. about 1360 — carries
fifteen NAME records, and the seventh is

```
1 NAME Dad ab Giwn
```

`GedcomFamilyGraph.people(matching:)` (`GedcomFamilyGraph+Index.swift:702`,
rung 1) is token-exact over EVERY NAME record of every person, so "Dad" is
an exact, unique hit, and every rung that guards recovery (the ≤4-letter
rule at `ArchivistGraphExecutor.swift:945`, the bare-given-name rule) is
never reached.

The road: "find videos of dad" matched the "videos of X" lineage shape
(`HallieLineageQuestion.swift:382`, which runs before the mode gate and before
the translator — the `[hallie-mode] … reason=conflict` line is logged after
the answer was already made) → `HallieLineageAnswer.personVideos`
(`+GedcomAwareness.swift:191`) → `resolveDetailed("Dad")`
(`HallieLineageQuestion.swift:1505`) → CyberBrain (no "dad" token) →
`ArchivistGraphExecutor.resolveSubject` → `people(matching:)` → Dafydd →
`photographyFloorLine(.film)` → the 1888 sentence. `[hallie] film offer
suppressed: Dafydd ab Einion … (b. about 1360 + 125 < film 1888)` is in
`videoscan.log` at 14:14:45 and 14:17:07.

GH #180 (9/11) fixed this for the person-fact lane (`HalliePersonFactQuestion
.swift:70` rewrites a bare kin word to "my dad") and 9/21 for the temporal
lane — each for its own road. Every lineage shape ("videos of X", "photo of
X", "X's line", "center on X", "X's family tree") shares ONE resolver, and
none of them asked whether X was a kin word first.

**Fix.** `HallieLineageAnswer+KinTerm.swift` — `ownerRelative(_:context:graph:)`,
called from `resolveDetailed` as step 0b, so every lineage shape gets it.
The ladder, first rung that settles wins: (0) a bare kin word a CURATED name
claims ("Ma" is Eileen's alias) keeps the alias road, as GH #180 ruled;
(1) the People tab's own relationship rows (Rick: "child of Dad") → the
relative's pinned tree record; (2) the owner's OWN tree record (FamilySearch
ID, else `HallieOwnerResolver`) → `relatives(_:of:)` or the extended walk;
(3) an honest decline naming the gap. Never a name lookup. Pinned by
`HallieDadNotDafyddTests` — the fixture tree keeps `1 NAME Dad ab Giwn` on a
1360 record, and `theTreeReallyHasAManNamedDad` proves the rung still fires
so the other tests still mean something.

### B. Two turns after the correction, "dad" was resolved from scratch

Turn 2 settled that "dad breen" is Richard Harding Breen Sr; turn 3 was about
him; turn 4's "videos of dad" ran the same lookup as turn 1 with no memory of
either. **Fix.** `ConversationMemory.kinBindings` (`HallieTurnExecutor
+Conversation.swift`): an ANSWERED graph turn whose typed person term names a
kin word ("dad breen", "my dad", "dad") writes relation → settled person
(`father` → "Richard Harding Breen Sr"); graph answers only, because a catalog
answer's person can be the contested given name "Richard". `lineageTurn`
substitutes the bound person into a media ask before any lookup — the same
road "photos of him" takes. Pinned by
`afterTheCorrectionVideosOfDadKeepsRichardSr`, with a People tab that has NO
relationship rows and a tree with NO parents for the owner, so only the
conversation can bind it; `aDeclinedCorrectionBindsNothing` and
`aFatherBindingNeverLeaksToMother` are the sensors.

### C. The tree opened on the man Rick had just rejected

Log, 14:15: `[hallie-mode] mode=tree reason=explicitCue(dad)` at 14:15:07 →
`Hallie: phrased graph/answered by template (template: model timeout)` at
14:15:28 → `Family Tree: selected Dafydd ab Einion … (@IB21341@)` and
`[family-tree] focus kind=record-id result=applied` at 14:15:29. The only code
that writes *"Opening the Family Tree tab focused on X."* is the window's own
chip handler (`ArchivistChatWindow.swift:1036`, `announce: true`); the
commit path's auto-focus sink announces nothing and writes `[family-tree]
Hallie focus requested target=person-id`, which is absent. The web bridge
turns tree offers into "tell me about X" asks. So turn 1's **superseded**
"Open in Family Tree: Dafydd …" chip was tapped in the second the corrected
answer landed. A chip tapped while Hallie thinks is dropped silently
(`handle(chip:)` `guard !isThinking`) — during a 21 s timeout that invites
repeat clicks, and the last one lands on the first frame after thinking ends.
Whether Rick's hand or something else pressed it, the chip should not have
been live: the conversation had moved from Dafydd to Richard Sr, and memory's
`tree.lastOffers` (what "show me" acts on) already forgets an earlier
answer's offers on every new tree answer. The transcript did not.

**Fix.** `HallieSupersededOffers.swift` (pure) + a `retireSupersededOffers`
sink on `HallieResponseCommit.Sinks`, called when the settled person changes,
BEFORE the new answer's bubble is appended (so a which-one's own chips are
untouched): earlier bubbles' `openFamilyTree` / `openFamilyTreePerson` chips
for anyone else are removed; asks, folders, surnames and app-tab chips stay.
`ArchivistChatWindow.handle(chip:)` now logs every tap — `[hallie] chip
tapped: …` / `chip ignored while thinking: …` — so next time the trail exists.
Pinned by `HallieSupersededOffersTests` (the pure function, the commit
order, an answer about the same person retires nothing, and an immediate
action only ever opens the result's own person).

### For Rick's ruling

- **Retiring old chips is a visible change.** After the conversation moves to
  someone else, an earlier bubble's "Open in Family Tree: X" button is gone;
  ask about X again and it is offered afresh (the same words
  `HallieTreeFollowUp` uses for a stale offer). The gentler alternative is a
  confirm-on-tap ("that was about Dafydd; still want the tree on him?") —
  more UI, and it would still have needed the tap to be logged.
- **A chip tapped while Hallie thinks is dropped without a word.** Disabling
  chips visibly while thinking would need `isThinking` in every row's
  equality (two re-renders per turn — cheap, but it is the row that the
  2026-08-29 beachball fix made equatable on purpose). Not done here.
- The unmerged `fix/hallie-kin-term-collision` (dfffe347, "a kin term names
  WHO, it does not argue about the mode") is NOT needed for this fix and was
  not cherry-picked: the Dafydd answer was made before the mode verdict, and
  `mode=unknown reason=conflict` on turns 1 and 4 only means the translator
  ran afterwards. That branch's ruling — whether "videos of my dad" should
  route to the catalog outright — stands as it was.
- `1 NAME Dad ab Giwn` is a legitimate FamilySearch alternate name; nothing
  to fix in the data. The lesson is in the resolver, not the record.

### Same matcher, one road over: the graph route (found by the sensor, fixed)

Two probes written for the same fixture went red on the graph route:
"show dad's family tree" (`.graph(people: ["dad"], operation: .familyTree)`)
rendered Dafydd's tree with an "Open in Family Tree: Dafydd" offer, and "who
is dad's mother" (`.kinship`, relation `.mother`) answered for Dafydd.
`HallieTurnExecutor+GraphPreflight.swift` rebinds only a "my/our <kin>"
PHRASE in the question (`SpeakerKinship.kinshipPhrase`); a bare "dad"
subject went straight to `ArchivistGraphExecutor.resolveSubject` and the
same `people(matching:)` rung. (`executeRelativeFact`, GH #180, runs first
but claims only biography / birth / death.) **Fix**, same file: a bare kin
word that is the ONE subject, not a curated alias, is read as "my <kin>" and
sent down the existing `SpeakerKinship.rebind` ladder — People tab → owner's
tree record → honest failure — for every remaining graph operation. Pinned
by `showDadsFamilyTreeIsNeverDafydd` / `whoIsDadsMotherIsNeverDafydd`.
Not covered (unchanged, reported): a bare kin word outside the rebind
vocabulary ("grandma", "nana") on a family-tree / kinship op still reaches
the name resolver; the biography ops already handle those through
`executeRelativeFact`.

**Runs (branch `fix/hallie-dad-dafydd`, worktree, Debug, M4, suite-filtered).**
Red first: `HallieDadNotDafyddTests` 10 of 13 red on the unfixed code with the
live symptom reproduced through the fixture (Dafydd for "dad", "my dad", the
photo shape, the post-correction turn); the two graph-route probes red on the
lineage fix alone. Green: every `Hallie*` / `Archivist*` / `People*` suite —
**1,855 Swift Testing tests in 226 suites + 7 XCTest, 0 failures, 257 s**
(`HallieDadNotDafyddTests` 15, `HallieSupersededOffersTests` 8 among them);
pytest `test_hallie_question_testbed.py` + `test_hallie_harvest_queries.py`
(+ `test_hallie_eval.py`) 66 passed, 17 subtests. Harvest: `lv260926-001`
by `hallie_harvest_queries.py --since 2026-09-26 --append`; `002…004` by hand
(the harvester skips a mid-sentence "not", a bare "sure" and "sure, but …").

## 2026-09-26 — "find the earliest birth year for richard's tree" → Gruffudd ap Einion b. 780 (Donna's line), and the corrections drew biographies

Rick, 16:46–16:49 ET (session `E1832598`, app; the transcript's `Z` stamps are
UTC). Rick's words: *"Example query that worked well: 'Find earliest birth
year in...' but I noticed it did not go to me, so I added 'for Rick' and got
that same answer, this person is not an ancestor of Rick."* Corpus
`lv260926-006…012`; strict `strict-060…064`; branch
`fix/hallie-superlative-scope`.

| # | id | asked | what came back | status |
|---|----|-------|----------------|--------|
| 1 | `lv260926-006` | "who is the earliest ancestor in my family tree" | the model's tree SUMMARY ("39249 people, birth years from 780 to 1959 … tell me whose tree you want") | open, follow-up candidate (see below) |
| 2 | `lv260926-007` | "find the person in the family tree with the earliest birth date" | *"The earliest birth year in the family tree is born 780: Gruffudd ap Einion …"* — `superlative: earliestBorn scope=wholeTree` | fine — **sensor**, must not change |
| 3 | `lv260926-008` | "… with the earliest birth date **who is a direct ancestor to rick**" | the SAME answer, `scope=wholeTree` | **FIXED** (A) |
| 4 | `lv260926-011` | "that person b. 780 is donna's ancestor, not mine. I want mine" | Rick's own biography (`operation=familyTree person=Rick Breen`) | **FIXED** (B) |
| 5 | `lv260926-009` | "find the earliest birth year **for richard's tree**" | the SAME answer, `scope=wholeTree` | **FIXED** (A) |
| 6 | `lv260926-012` | "that is donna's line" | Donna's biography (`operation=familyTree person=donna`) | **FIXED** (B) |

**Failure class.** The 9/07 shape yet again — a true, cited answer to a
different question, twice — and then the corrections were answered as if
they were new questions. Row 6 is the sharpest: Rick told Hallie whose line
the answer was from, and she described that person.

### A. The scope reader knew "of X's ancestors" and nothing else

`HallieLineageQuestion.superlativeKindAndScope` (the scope block, formerly
`HallieLineageQuestion.swift:1100–1116`) accepted exactly two person forms:
`of|among|in|from X's ancestors|ancestry|forebears|line|lineage|pedigree` and
`ancestor(s) of X` at the end of the sentence. Not "for", not "tree" /
"family tree" / "side", not "ancestor **to** rick", not a relative clause,
not a trailing "for rick". Every scoped ask fell to `.wholeTree`, the log
said so (`scope=wholeTree`), and the whole-tree winner is on Donna's side.

**Fix.** `HallieLineageQuestion.personScope(in:)` — one reader, first match
wins: (1) a trailing relative clause "who|that is a (direct) ancestor|
descendant of|to X"; (2) a trailing "for X" / "for X's tree" (never "for
example"); (3) a possessive after a preposition, `of|among|in|from|for|on|
within|across X's ancestors|line|side|tree|family tree|family|descendants…`
— "my/our family tree" stays the WHOLE tree, as pinned 2026-08-26;
(4) "ancestor(s)|descendant(s) of|to X" at the end. A name is a run of name
TOKENS, never a grammar word, so "born in ireland among rick's ancestors" is
read from "among" (the first cut of this read "ireland among rick" as the
name, and the birthplace kind read "Ireland Among Rick's Ancestors" as a
place — both caught RED by the new suite). The reader also returns its
RANGE so the birthplace kind stops its place capture where the scope starts.
`SuperlativeScope` gains `.descendantsOf(String?)` ("X's descendants") and
`.otherSideOf(String?)` (only ever produced by a correction, see B).

The answer (`HallieLineageAnswer+Superlatives`) walks the person's ancestors
with the biography's own enumeration (`GedcomFamilyGraph.ancestorLine`,
de-duplicated by the walk's `seen` bitmap — the same count the family-tree
card reports as "N recorded ancestors across G generations") or descendants
(`descendants(of:depth:)`), and SAYS what it ranked: *"The earliest birth
year among Richard Harding Breen Jr’s 6 recorded ancestors is born 1860:
Patrick Breen …"*; basis *"Ranked 6 of Richard Harding Breen Jr’s 6 recorded
ancestors across 3 generations that record the fact."* The whole-tree and
surname wording is byte-identical to before (sensor C:
`theUnscopedSuperlativeStillRanksTheWholeTreeWordForWord` pins prose, basis,
query description and chips on the fixture; strict-060 pins it on the real
tree). "richard" resolves the way every lineage shape resolves a name — the
owner's FamilySearch pin settled it in the fixture and the People-tab bridge
did live ("Richard Harding Breen Jr (Richard in the People tab)"); a genuine
tie asks which one, as elsewhere.

### B. Nothing remembered the ranking, so the correction became a question

"that is donna's line" reached the translator, which read it as a family-tree
card for Donna; "not mine. I want mine" became Rick's card. `HallieRepairTurn`
did not fire either — neither sentence carries a complaint cue.

**Fix.** Three small parts, in the `kinBindings` style of the morning's fix:
- `Result.superlative` — a typed payload (kind + the scope as RUN) set only
  by `HallieLineageAnswer.superlative`, on answers, declines and which-ones
  alike; carried by every copy helper (`HallieResultCopyRoundTripTests`
  walks them). Typed, never parsed back out of prose or the query
  description (codex #1352's ruling for `retryOffer`).
- `ConversationMemory.lastSuperlative` — taken from that payload; replaced by
  the next ranking, cleared by any other lane answer (a correction two
  questions later is not misread), kept across follow-ups / help / small
  talk; reset clears it.
- `HallieSuperlativeCorrection.scope(in:)` (pure) — "I want mine" / "not
  mine" / "that's not my side" / "I meant rick" / "no, I meant for rick" /
  "for rick" / "what about donna's side" / "donna's side" → that person's
  ancestors; "that is donna's line" / "those are donna's ancestors" → the
  OTHER side (`.otherSideOf`: the owner's ancestors when X is not the owner,
  the spouse's when X is — "that is my line"). Runs in `preTranslationSingle`
  BEFORE the repair turn, only while a ranking is remembered, and abstains on
  anything `HallieLineageQuestion.detect` claims, so a fresh "who is the
  oldest person on donna's side" is its own ranking, never a correction.
  The corrected answer carries the payload too, so a second correction
  works ("that is rick's line" → Donna's).

### Not fixed here, reported

- **Row 1, "who is the earliest ancestor in my family tree".** No born/birth
  word, so the superlative reader stays silent and the translator's tree
  summary answers (true, cited, not the person). "earliest / first ancestor"
  → earliest-born over the owner's ancestors is a one-regex addition to the
  kind reader, but it is a second bug and this dispatch is one bug.
- **Same gap, one road over:** `HallieTreeStatisticsQuestion.ancestorScope`
  knows only "my/our ancestors" / "my line", so "how many of **rick's**
  ancestors were born in ireland" counts the whole tree. That route's engine
  scope is owner-only (`TreeStatistics.Scope.ancestors(of:)` resolves the
  owner); naming a person there is a small feature, not this fix.
- **Precedence, pre-existing:** "who was born first among my ancestors" is
  claimed by the birthplace-trail shape, which runs before the superlatives;
  "who is the oldest person among my ancestors" is a superlative. Left as is.
- **A name with a grammar word in it** ("john of gaunt's ancestors") is cut
  at the grammar word by the scope reader ("Gaunt"). Superlatives scoped to a
  medieval name are rare; the resolver's which-one / not-found is the
  fallback.

**Runs (branch `fix/hallie-superlative-scope`, worktree, Debug, M4, suite-filtered).**
Red first: `HallieSuperlativeScopeTests` 14 issues on the unfixed code with the
live symptom reproduced through the fixture (the scoped asks and the
corrections), then the two reader bugs above caught by the same suite. Green:
every `Hallie*` / `Archivist*` / `People*` suite — **2,145 Swift Testing tests
in 260 suites + 7 XCTest, 0 failures, 1 pre-existing known issue, 286 s**
(`HallieSuperlativeScopeTests` 11, `HallieSuperlativeTests` 7 and
`HallieResultCopyRoundTripTests` 2 among them); pytest
`test_hallie_question_testbed.py` + `test_hallie_harvest_queries.py` +
`test_hallie_eval.py` 66 passed, 17 subtests. Harvest: `lv260926-005…010` by
`hallie_harvest_queries.py --since 2026-09-26 --append`; `011` and `012` by
hand (a mid-sentence "not" and a bare statement), placed in conversation order.

**Follow-ups closed 2026-10-01 (GH #200, #214; branch on the feature-dev
worktree).** Row 1 ("who is the earliest ancestor in my family tree") is now
answered by the ancestor-line route — the earliest recorded birth over the
owner's AND the partner's lines, with how many could be ranked, and the other
side's own earliest; corpus row `lv260926-006` carries the expectation
(confirm live). The person-scoped gap is closed: "how many of rick's / donna's
ancestors …" counts that person's line through the shared scope reader, in
both statistics routes. Found on the way: the router's year-bound peel
(`HallieLineageQuestion.detect`) removed "before 1900" before the statistics
recognizers saw it, so "how many … were born before 1900" counted everyone and
read as complete — fixed, regression test in `HallieAncestorStatisticsTests`.
New corpus rows `ts261001-001…012`.
