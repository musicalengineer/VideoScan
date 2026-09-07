# Hallie — spreadsheet-style questions about the tree

Status: **PROPOSED**, awaiting Rick. Written 2026-09-07 from his own framing:

> "imagine a query 'list about 100 people who were born in another country' or
> in europe or in ireland or UK. these kinds of queries will be very helpful.
> Basically like asking an excel spreadsheet to compute averages, medians, etc."

This is a different **shape** of question from everything Hallie does today.
Every existing route answers about *one person* or *one line of descent*.
This asks the whole table a question and expects a **set** or a **number**
back.

## Why it is worth doing: the data is already there

Measured on Rick's tree (16,383 people) — no new ingestion, no schema change:

| | |
|---|---|
| people with a recorded birthplace | **15,211** (93%) |
| born outside the US | **14,851** |
| distinct birth countries | **204** |
| England / UK / France / Wales / Scotland | 11,280 / 1,641 / 600 / 392 / 309 |
| lifespans computable (birth *and* death year) | **11,920** |
| mean / median lifespan | **57.5 / 58 years** |
| median birth year | **1420** (range 1010–1959) |

Rick's three example asks all return real answers today if something will run
them. "About 100 born in another country" has 14,851 candidates to draw from,
not 3.

## Rick's fuller framing (2026-09-07)

> "computer software is good at this kinda stuff, finding patterns, averages,
> outliers, finding things humans overlook. This app should be able to do
> these things and hallie is the interface to finding these things. I don't
> literally want a spreadsheet, unless it is necessary to show some important
> demo/bio data trends ... other examples include compute average ages for
> groups, how many people live in what location, how many generations between
> Ireland and Boston."

So: **Hallie is the interface, not a spreadsheet UI.** A table is an output
format for when a trend needs showing, never the thing being asked for. And
"how many generations between Ireland and Boston" adds a capability the filter
+ aggregate model above does not cover — see below.

### A third answer kind: distance along a line

Not a filter and not a statistic — a **path** between two places, measured in
generations, with the chain shown. Run against Rick's tree it already answers:

```
"how many generations between Ireland and Boston?"   →   2

   gen 2   Mary Catherine O'Connor    Ireland
   gen 1   Eileen Latta               Chelsea, Suffolk, Massachusetts
   gen 0   Richard Harding Breen Jr   Boston, Suffolk, Massachusetts
```

His grandmother was born in Ireland; he was born in Boston. The answer must
show the chain, because the number alone ("2") is unverifiable and this is
precisely the class of claim that has to be checkable.

Note what it must NOT do: pick the *shortest* span and call it "the" answer
without saying so. Several Irish-born ancestors exist on different lines; the
nearest crossing is one fact among several and the wording has to say which
it is.

### The outliers Rick actually wants

"Finding things humans overlook" is the point, so the first aggregate work
should make these askable: longest and shortest lives, the generation where a
line changes country, families with unusually many or few children, people
with no recorded death, the decades with the most births. Each is arithmetic
over recorded fields — no inference about people.

## The shape

Two answer kinds, and they need different honesty rules.

**A list** — "list about 100 people born in Ireland". Bounded, paged,
continuable ("show me more"), and it must say the total it drew from: *"41
people in the tree have a recorded Irish birthplace; here are 25."*

**A statistic** — "what was the average lifespan", "how many were born
abroad". The rule that matters: **the denominator is the recorded population,
never the tree.** 11,920 of 16,383 people have a computable lifespan, so an
average lifespan is an average over 11,920 and the answer must say so.
Reporting "57.5 years" without that is a fabrication of coverage.

## Filters worth having first

Composable, each one already computable from `Person` plus
`BirthplaceClassifier`:

- **place** — country (`Ireland`), continent (`Europe`), outside-a-country
  (`not the US`), or a raw recorded region (`New England`)
- **time** — born/died before, after, or between years
- **scope** — the whole tree, or Rick's ancestors only. These are *different
  answers* and must never be conflated (codex #1157). 12,045 of Rick's
  ancestors are Europe-born; 14,851 people in the tree are foreign-born.
- **relation** — a named person's descendants or ancestors

## Aggregates worth having first

`count` · `average` · `median` · `min`/`max` · `group by country or century`.
Deliberately not: anything requiring inference about people, only arithmetic
over recorded fields.

## What must never happen

The lesson of 2026-09-07, when four separate questions were answered
confidently with something else:

1. **An unrecognised filter is said out loud**, never silently dropped. "List
   people born in Ruritania" answers "no recorded birthplace matches
   Ruritania", not a list of everyone.
2. **Zero results is an answer**, not a fallback to a different question.
3. **Every count states its denominator** and the number of records with the
   field unrecorded.
4. **Colonial and historical names are reported as recorded.** "British
   Colonial America" (269 people) is not silently rewritten to "United
   States", and a place that spans today's borders is reported and not
   counted — the existing `BirthplaceClassifier` ambiguity rule.

## Proposed first slice

One filter — place — one aggregate — count — and a bounded, paged list.
"How many people in the tree were born in Ireland?" and "list them". That
exercises the whole path (detect → filter → count → bounded list → prose with
denominator) without the grouping, time or scope-combination work, and it
answers one of Rick's three examples outright.

Reuse, per codex #1161/#1162: the compiled index already scans the whole tree
cheaply, and `BirthplaceClassifier.classify` already maps a raw place string
to country and continent. No full-tree scan belongs in a view body — the
project's standing rule, and the reason the 100k-scale budget test exists.

## Proof the tree carries the fun answers too

Asked of Rick's own line, not Donna's — he assumed the royalty came with his
marriage:

```
RICK'S OWN ROYAL ANCESTORS
   gen 20   Edward III of Windsor, King of England    b. 13 November 1312
   gen 20   Philippa de Hainaut, Queen of England     b. 24 juin 1314
```

Recorded in the imported tree, twenty generations back, on FamilySearch's
user-submitted medieval lines — a claim the tree makes, never a proven
descent, and the wording must always say so. (Note the raw date is French,
"24 juin 1314": another reason place and date strings are shown as recorded.)

## Open for Rick

- Whole tree or your ancestors, when the question does not say?
- "About 100" — is a page of 25 with "show me more" the right shape, or do you
  want the whole list in one block to paste elsewhere?
- Should these answers be copyable the way a person's details now are
  (`c54e5c4c`, "Copy details")? A 100-row answer is a spreadsheet's worth of
  text.
