# Hallie — titled ancestors and European lines

Status: **PROPOSED**, awaiting Rick. Written 2026-09-07 after Rick asked
"can you get Hallie to answer questions like going back to European titled
people?" and found *"Patrick, I Laird of Hailes Hepburn"* himself.
codex's bounded plan is #1157; this is the audit it asked for first, plus the
one architectural finding that changes the plan's shape.

## 1. The audit — is there title evidence at all?

Yes, and more than expected.

| | Rick's tree | Donna's tree |
|---|---|---|
| names | 31,520 | 58,464 |
| strict title matches | 1,157 | 2,650 |
| highest rank present | King/Queen of England, Scotland, Mann | King of Scotland |

**There is no structured title field.** The 69,526 `TITL` tags in Rick's
GEDCOM are level-1 and level-2 source/media titles — `IMG_5311.jpg`,
`Eliza Brooks (1803-1881) Birth Record`. Not one is a person's rank.
`GedcomFamilyGraph.Person` has no title field and the parser has no `TITL`
handling for people, exactly as codex reported.

Every title in this tree lives **inside the NAME string**:

```
Patrick Hepburn of Dunsyre, 2nd Lord Hailes, 1st Earl of Bothwell
Adam Hepburn of Hailes Earl of Bothwell Sheriff of Berwickshire kt
Philippa de Hainaut Queen of England
David Home, 1st Laird of Wedderburn
```

Rick's Laird of Hailes is on **Donna's** side, not his own.

## 2. The trap, measured

A keyword match on rank words is wrong 24% of the time. Rank words are
ordinary English surnames and given names:

```
Hannah King        Alice Knight        Earl Stanley Damon
Elizabeth King     Thomas King         Martha Brady Lady
```

782 naive matches vs **597 real ones** in Rick's tree — 185 false positives.
Telling Rick that Hannah King was royalty is worse than saying nothing, so
detection is three explicit patterns, not a word list:

1. ordinal + rank — `8th Laird of Thornydykes`, `3rd Duke of Buckingham`
2. rank + `of` + place — `Countess of Bedford`, `Laird of Hailes`
3. honorific opening the name — `Sir John Dering`, `Lady Alicia Pembridge`

A bare surname match is rejected. This is a deterministic string rule, which
is what the 2026-08-14 decision asks for: the composer is deterministic Swift
and the model only phrases.

## 3. Ancestors, not "in the tree"

codex's sharpest point. Of 597 strict matches in Rick's tree:

- **482 are direct ancestors** of Richard Harding Breen Jr, across 21 generations
- 115 are collateral — real people in the tree, not on Rick's lines

"Going back to titled people" means the ancestor set, and the two must never
be conflated in an answer. The traversal already exists (`HallieBirthplaceTrail`
walks ancestral lines with cycle guards and paging); the deepest titled
ancestors sit at generation 20, which is the pull depth, so the wall is the
GEDCOM's, not the code's.

## 4. The architectural finding — no schema change needed

codex's plan assumed title preservation across parser → compiled cache →
version → merge → writer → display, and gated that on Rick's schema approval.

**That gate can be skipped, because there is nothing to preserve.** The title
is already in `Person.name`, which every one of those layers already carries.
A title index is *derived* at load time from names the graph already holds —
no new field, no codec bump, no merge semantics, no migration, and nothing
that can be lost on reload. The reload-loses-titles test codex wants becomes
structurally impossible rather than merely covered.

If a future FamilySearch pull ever carries real typed titles, that is the
moment to revisit persistence. Today it would be schema churn for data that
does not exist.

## 5. Proposed slices

**Slice 1 — `HallieTitleClassifier`** (no UI, no route). The three patterns
above, `TitledPerson { person, rank, titleText, seat }`, a rank ordering
(emperor > king > prince > duke > marquess > earl > viscount > baron > laird >
lord > knight). Tests: the 185 known false positives stay rejected, the four
real examples above parse, rank ordering is total, 100k-name budget.

**Slice 2 — the ancestor query.** "the highest title going back", "titled
ancestors", "royalty in the family". Reuses the birthplace-trail traversal
against a stable root; answers name the generation and the line, and say
**ancestor** or **also in the tree** explicitly. Tests: collateral branch must
never be reported as an ancestor, ambiguous root, cycle guard, no full-tree
scan in a view body.

**Slice 3 — routing.** Today "in the family tree going back, find the highest
level of royalty" searches *video filenames* — Rick hit this live this
morning, three turns running, and the third read "Title like king" as a
person's name and offered to remember it. The tree route needs a
title/keyword cue, and the refinement path needs to survive a route change
("not in videos, in family tree" currently answers "I can only drop a person,
not a topic word"). Harvested as `lv260907-00x`.

## 6. What the answer must never claim

These are FamilySearch user-submitted lines. A queen at generation 20 is a
recorded claim, not a proven descent, and the further back it goes the less
it is worth. Wording is therefore fixed: **"the imported tree records X as
…"**, never "you are descended from". No invented geography, no inferred
nobility, no authentication we have not done. Rick's own rule — the People tab
is the source of truth, the tree is frequently wrong about even his parents'
dates — applies with far more force twenty generations out.
