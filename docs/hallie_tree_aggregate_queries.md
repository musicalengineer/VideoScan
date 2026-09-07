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

## Open for Rick

- Whole tree or your ancestors, when the question does not say?
- "About 100" — is a page of 25 with "show me more" the right shape, or do you
  want the whole list in one block to paste elsewhere?
- Should these answers be copyable the way a person's details now are
  (`c54e5c4c`, "Copy details")? A 100-row answer is a spreadsheet's worth of
  text.
