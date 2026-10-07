Brief: N1007-D-Hallie-rewrite-eval | Source: main@c86b926 | Wall clock: 45 | Files read: 12
Finding count: 5 (REAL 3 / NEEDS-MAC 2 / NOISE 0)
Verdict: Refactor, not rewrite: the parsers are already an ordered first-match table written as an if-chain, so convert them in place to an ordered rule array behind a back-to-back oracle. Size M for the lineage parser, S for persona, M for the relationship executor. The relationship executor is not a parser at all, and two of the brief's four complexity numbers are lizard parse artifacts.

# N1007: Hallie question parsers, rewrite or refactor?

Scope (from the brief): `HallieLineageQuestion.swift` (detection half, lines 1–1402), `HalliePersonaQuestion.swift`,
`HallieTurnExecutor+Relationship.swift`, and the four corpora.
Callees followed to settle findings: `HallieLineageAnswer.answer` / `.centerTree` (same file, lines 1460–2001), the
call sites of `detect` (grep only), `scripts/hallie_eval.py` and `scripts/nightly_hallie_replay.sh` (headers only, to see
how the corpora are run), and the test names in `HallieRelationshipTests.swift`.
Mechanical scan, not a read: every string literal in `VideoScan/VideoScanTests/*.swift` (27,183 literals) was run through
the same branch port as the corpora. That separates "no corpus reaches it" from "nothing pins it".
Not read: the out-of-file recognizers `HallieAncestorStatisticsQuestion`, `HallieTreeStatisticsQuestion`,
`HallieBirthplaceTrail`, `HallieKinshipApposition`. They are treated as opaque.

**Scope notes for the Manager**
- `executeRelationship` is an identity-resolution executor (owner chain, alias ladder, chip continuation). It parses no
  text. "Table-driven" does not apply to it; it gets an ordinary extract-function plan (item 4 below).
- `tests/hallie_strict_regressions.json` is the corpus that actually gates (the STRICT lane of the nightly replay), and the
  brief doesn't list it. I didn't read it. The back-to-back oracle in step 1 should include it.
- No `metrics/complexity.jsonl` exists on `origin/metrics` (the branch has `history.jsonl`, `static_analysis.jsonl` and
  others), so step 0 of the D checklist had nothing to start from. The numbers below are tonight's own.

---

## 0. Measurements: what is actually complex

The brief's numbers come from lizard 1.2x on the raw files. Lizard's Swift reader doesn't understand Swift 5.7 regex
literals (`/…/`). It sees the word `get` inside `/\b(?:get|fetch|…)\b/` as a property accessor and splits or merges
functions around it. I re-ran lizard after replacing all 130 regex literals in the file with `""`. I also hand-counted
decision points (if/guard/&&/||/for/while/case/??), because lizard drops lines 228–301 of `detectShape` even after the
regex literals are neutralised.

| Brief says | What it really is | Honest size |
|---|---|---|
| `HallieLineageQuestion.get` CCN 93 (line 595, 87 lines) | Not a function. Lizard's span covers the tail of `isFetchClause`, all of `gedcomProvenanceQuestion` and all of `commonAncestorQuestion` | `isFetchClause` 7, `gedcomProvenanceQuestion` 11, `commonAncestorQuestion` 10 |
| `get` CCN 17 (line 573) | The `interrogativeFetchClause` regex constant | not a function |
| `detectShape` CCN 88, length 335 | `detectShape` (228–434) merged with `mediaAskPerson`, `personTreeQuestion` and `centerTreeQuestion` | ≈48 decision points over 207 lines, 30 branches |
| `HalliePersonaQuestion.init` CCN 72 | There is no init. It is `HalliePersonaQuestion.detect` (lines 103–213), misnamed | ≈72–80; about 60 of these are `padded.contains(" … ")` phrase alternatives, which is data written as code |
| `executeRelationship` CCN 50 | Correct | 50 CCN, 293 lines |

Real hot spots in the detection half of `HallieLineageQuestion.swift` (regex literals neutralised): `detectShape` ≈48,
`superlativeKindAndScope` 25, `personScope` 13, `gedcomProvenanceQuestion` 11, `detect` 11. Everything else is ≤10.
The file holds 95 regex-literal call sites (105 `firstMatch` calls). The file is 2,077 lines, but only 1,402 are
detection; lines 1404–2077 are `HalliePersonVitals` and `HallieLineageAnswer`, which are out of scope tonight.

---

## 1. What the corpora pin

### 1a. How the corpora are run (this decides what "pinned" means)
- `hallie_interaction_corpus.json`, `hallie_live_misses_corpus.json` and `hallie_eval_corpus.json` are run **end to end**:
  real app, real local model, by `scripts/hallie_eval.py` from `nightly_hallie_replay.sh` on the M4. They are graded on
  route / outcome / mustContain, and the eval corpus is **ADVISORY** (it never fails). None of the three is loaded by
  XCTest, apart from `HallieTypoVariantGeneratorTests` reading the eval corpus as typo-generator input.
- `archivist_golden_answers.json` is loaded by `ArchivistGoldenAnswerTests`, but its cases are translator/AST cases
  (`modelOutput` given), not `HallieLineageQuestion.detect` outputs.
- **So no corpus pins a parser branch in CI.** What CI pins is about 30 Swift test files that call
  `HallieLineageQuestion.detect` or a sub-parser directly (`HallieLineageTests`, `HallieCommonAncestorTests`,
  `HallieCenterTreeTests`, `HallieSuperlative*Tests`, `HallieDeepAncestorTests`, `HallieKinship*Tests`,
  `HalliePersonaQuestionTests`, and others). The corpora pin routes, nightly, with the model in the loop, and lane
  ordering upstream of `detect` can hide a parser change.

### 1b. Branch reach
Method: a Python port of every branch trigger in `detect` / `detectShape` and of `HalliePersonaQuestion.detect`
(appendix A). Each corpus sentence is checked against each branch. Inside one recognizer (for example the 10
common-ancestor patterns) first-match order is honoured. Across recognizers each is evaluated independently, so "reached"
is an upper bound. The four corpora give 985 unique sentences. The persona oracle `isInnerCircleName` is taken as always
false.

**Lineage parser:** 84 branch leaves. **41 are reached** by at least one corpus sentence and **43 are not**. Of those 43,
**11 are reached by no test string literal either**. Those 11 are the real gaps (F2).

| Reached by the corpora (count of sentences) | |
|---|---|
| videos of X | 38 |
| named-kin sentence ("who are X's sons") | 23 + 4 pronoun |
| maternal/paternal line | 15 (7 of them claimed earlier by trace / kinship / superlative) |
| "what was X like" | 10 (most are persona-past questions, not description asks; see note) |
| common ancestor: "how am I related to X" / pair patterns p1–p5, p7 / "our common ancestor" | 8 / 21 / 2 |
| photo of X, person tree (named), grand-kin with and without side, family tree for <surname> | 7, 6, 12, 5 |
| superlatives: earliest born, latest born, first born in, deepest ancestor | 5, 2, 1, 1 |
| trace (to a place 5, family-word 5), describe X 3, the <surname> family tree 3, the rest | 1–3 each |

**Not reached by any corpus sentence (43).** † = also reached by no Swift test string (the 11 gaps).
- Fetch the tree: all four forms (FamilySearch, verb + tree, "more generations", "update the tree"). Tests pin them.
- GEDCOM awareness: "how do you know the family tree" †, "what tree file are you using" †, a bare ≤3-word "gedcom" ask †
  (the only test hits are code fragments, not questions).
- Common ancestor: pair p6 (do A and B share an ancestor), p8 (A and B's common ancestor), **p9 (who is the common
  ancestor of A and B) †, dead: shadowed by p5, see F2**, p10 (where do A's and B's lines meet), and "our/we" forms p2–p7. Tests pin all except p9.
- Center tree: "take me to / go to X in the tree".
- Superlatives: longest lived, latest died, earliest married, most children (plain form tested). **Every media-wrapper
  variant except earliest/latest born ("photo of the person who lived longest") †, which is 6 leaves.**
- "what photos do we have for X"; "X's appearance"; "trace … back" with no place; "my family tree"; spouse "who was X
  married to" (both forms); fragment "my <kin>" / "X's <kin>"; deep ancestor (3+ greats, with and without side);
  "family tree of the <surname>s back to …"; pronoun videos ("show me her videos"). Unit tests pin all of these.
- **"starting with the <surname> …" + tree/descend, the standalone `starting (with|from)` rule (B26) †.** The one test
  sentence ("family tree starting with the …") is claimed one rule earlier by B25, so deleting B26 changes no test.
- Year-bound re-attach (`detect` lines 187–212): the three corpus sentences with a year bound all fall to statistics or
  nil. The ancestor-line re-attach, the origin-trail-to-walk conversion and the "X's ancestors before 1800" fallback are
  reached by no corpus sentence. `HallieLineageYearBoundTests` exists; per-leaf pinning not checked.

**Persona parser:** 19 leaves. **5 reached** by the corpora (`your <kin>` 12, `your <kin>'s` 1, `you have <kin>` 1,
when-born 1, where-born 1). **7 reached by nothing**: `you have a <kin>`, `you ever have <kin>`, `you ever have any
<kin>`, `you ever have a <kin>`, `you ever married`, `you ever marry`, `you marry` (F3). The persona-guard leaves
(year / search word / typed name / first person) are reached many times: 236 sentences hit the search-word veto.

Note on "what was X like" (10 corpus hits): at the parser level, persona-past sentences such as "what was school like for
you" become `.personDescription(person: "School")`. Lanes ahead of `detect` (the persona-past lane and the mode
classifier) keep them off this road, and tests pin those lanes (the same applies to "help me think of three questions to
ask my grandmother" → `.kinship(owner, grandmother)`, pinned in `HallieGeneralKnowledgeLaneTests` and
`HallieModeClassifierTests`). I'm not reporting these as findings. They are a **design constraint**: the oracle must
compare `detect()` outputs, not routes, and a new parser must reproduce these over-claims unless a deliberate, tested
change removes them. `HalliePersonFactQuestion` and `HallieSuperlativeCorrection` call `detect()` directly and depend
on its nil/non-nil answer.

---

## 2. Table-driven design (same interface)

The current `detectShape` is already a table in all but syntax: 30 branches, tried in order, first non-nil wins, each with
a dated provenance comment. The design makes that explicit without changing a single regex.

```swift
/// One recognised shape. `id` is the stable key the oracle, the coverage sensor and the shadow log use;
/// `since` keeps the live-miss provenance that today lives in the comment above each if-block.
struct HallieLineageRule: Sendable {
    let id: StaticString                 // "kin.spouse.didMarry"
    let since: StaticString              // "strict-004, live replay 2026-09-13; codex #1352"
    let claim: @Sendable (String) -> HallieLineageQuestion?
}

extension HallieLineageRule {
    /// The common simple case as DATA: one regex, optional lead-word / veto regexes,
    /// a word cap on capture 1, and a constructor. About 14 of the 30 branches fit this
    /// (photo-of, what-photos, pronoun photo/videos, describe, what-was-like, appearance,
    /// where-from, the four surname-tree forms, about-the-X-family, videos-of).
    static func regex(_ id: StaticString, since: StaticString,
                      _ pattern: Regex<(Substring, Substring)>,
                      requires: Regex<Substring>? = nil,
                      captureRejects: Regex<Substring>? = nil,
                      maxWords: Int? = nil,
                      build: @escaping @Sendable (String) -> HallieLineageQuestion) -> Self
}

enum HallieLineageRules {
    /// ORDER IS THE SPEC. Moving a row is a behaviour change and needs an oracle diff.
    static let ordered: [HallieLineageRule] = [
        .init(id: "tree.fetch",        since: "2026-08-25", claim: { isGetFamilyTree($0) ? .getFamilyTree : nil }),
        .init(id: "tree.provenance",   since: "live 2026-08-27; codex #754", claim: gedcomProvenanceQuestion(in:)),
        .init(id: "tree.awareness",    since: "2026-08-22", claim: { isGedcomAwareness($0) ? .gedcomAwareness : nil }),
        .init(id: "pair.common",       since: "2026-08-27 … 09-18", claim: commonAncestorQuestion(in:)),
        .init(id: "tree.center",       since: "live 2026-08-29", claim: centerTreeQuestion(in:)),
        .init(id: "stats",             since: "#214 / #200", claim: statisticsQuestion(in:)),       // opaque recognizer
        .init(id: "trail.birthplace",  since: "2026-09-02", claim: birthplaceTrailQuestion(in:)),   // opaque recognizer
        .init(id: "superlative",       since: "live 2026-08-26 … 09-26", claim: superlativeQuestion(in:)),
        .regex("media.photoOf", since: "2026-09-10", photoOfPattern, requires: photoLeadWords,
               captureRejects: conjunction) { .personPhoto(person: mediaAskPerson(in: $0)) },
        // … one row per remaining branch, in today's order …
    ]

    static func detectShape(_ lower: String) -> (HallieLineageQuestion, ruleID: StaticString)? {
        for rule in ordered { if let q = rule.claim(lower) { return (q, rule.id) } }
        return nil
    }
}

// Public interface unchanged:
//   HallieLineageQuestion.detect(_ text: String) -> HallieLineageQuestion?
// New, internal, test/shadow only:
//   HallieLineageQuestion.detectTraced(_ text: String) -> (HallieLineageQuestion?, ruleID: StaticString?)
```

What does **not** become data, deliberately:
- The helpers `possessor`, `namedTarget`, `scopeName`, `greatCount`, `capitalizedName` and `mediaAskPerson`. They're
  already small pure functions with their own pins. Rules call them.
- The four sub-recognizers that are already functions (`commonAncestorQuestion`, `kinshipQuestion`,
  `superlativeKindAndScope` + `personScope`, `personTreeQuestion`). Each becomes one row. Inside, the pattern lists
  (10 pair patterns, 7 "our" patterns) are already arrays.
- The year-bound pre-pass in `detect` stays as code in front of the table. It's a rewrite of the input, not a shape.

Persona: `HalliePersonaQuestion.detect` keeps its guard prelude as code. The tail (lines 169–212) becomes three
tables: `relativePhrases: [String]` (the 8 format strings × `kinWords`), `marriedPhrases`, and
`vitalCues: [(Ask, [String])]` in today's order (birth → age → death → origin), plus the 4-line birthdate/birthplace
opener rule. Its CCN drops from ≈72 to ≈20 with no regex involved.

---

## 3. Back-to-back plan (old and new side by side; switch at zero disagreements)

1. **Oracle first, on `main`, before any move (M4 night 1, size S–M).**
   - Sentence set → `tests/fixtures/hallie_parser_sentences.json`: the four corpora + `hallie_strict_regressions.json`
     + every multi-word string literal in `VideoScanTests/*.swift` (appendix A's extractor already does this) +
     HallieTypoVariantGenerator variants of the corpus + the 18 new sentences for the unpinned leaves (F2, F3).
   - A Swift test (`HallieParserOracleTests`) writes `detect(s)` (via `String(reflecting:)`, which is stable for these
     Equatable enums) and, for persona, `detect(s, isInnerCircleName:)` under two fixed oracles (always false; a fixed
     set of 3 names), to `tests/fixtures/hallie_parser_oracle.json`, generated at a recorded SHA and committed.
2. **Rename, don't edit (night 2).** Move today's `detectShape` body verbatim into `HallieLineageLegacy.detectShape`.
   Add `HallieLineageRules`. First pass: each row's `claim` is the old if-block pasted into a closure, so the behaviour
   is identical by construction. A test `parserBackToBack` runs legacy and new over every oracle sentence and fails
   with a full disagreement list: `ruleID | sentence | legacy | new`.
3. **Coverage sensor (same night).** `detectTraced` over the oracle set must hit **every** rule id at least once. That
   sensor makes this report's question a test failure from now on: a rule nobody reaches can't land.
4. **Convert rows to declarative `.regex` rows one at a time**, each a commit with back-to-back green. Move the dated
   comments into `since:`.
5. **Shadow in the app (one week).** Behind a `HallieParserShadow` default (off in Release builds), `detect` runs both
   and writes one line per disagreement through the single log sink (`START/OUTCOME` style, rule id + both shape
   descriptions; the question text is already in Hallie's own conversation log, so this adds no new exposure). The
   nightly replay runs with shadow on.
6. **Switch** when back-to-back = 0 and the shadow log has been empty for 7 days of Rick's use plus 7 nightly replays.
   Keep the legacy code behind the flag for one more week, then delete it in its own commit.
7. Persona follows the same steps 1–6 in one night; it's small.

---

## 4. Recommendation: refactor, not rewrite

- **Behaviour is accreted rulings, not a grammar.** About 60 dated live misses and codex rounds are encoded as small
  exceptions: "their" excluded from pronoun kin (codex #1352), `for example`/`for now` stop words, the 8-word cap for
  long royal names, "8th" not capitalised, nested-kin subjects refused, "my family tree" = whole tree in superlatives.
  A clean-room rewrite would re-lose each one and pay for it in live misses. The oracle would catch the losses, but at a
  triage cost of hundreds of disagreements.
- **Order is already the semantics.** Turning an ordered if-chain into an ordered array is mechanical and provably
  identical (step 2). The structural win (ids, coverage, provenance as data, declarative rows) comes from the refactor.
- **Sizes:** lineage parser M (2–3 M4 nights: oracle, legacy move + rules + sensor, row conversion). Persona S
  (1 night). Relationship executor M (1 night, independent of the other two). Rewrite estimate for comparison: L–XL with
  open-ended disagreement triage.
- Expected result: `detectShape` goes from ≈48 to ≈2 (a loop), with each rule ≤8. Persona `detect` goes from ≈72 to
  ≈20. `executeRelationship` goes from 50 to ≤15 with four extracted helpers.

---

## Findings

### N1007-D-Hallie-rewrite-eval-F1: P3, REAL. Complexity metric keys on phantom symbols
- **Symbol:** `HallieLineageQuestion` (lizard rows `get@573`, `get@595`, `detectShape@228`), `HalliePersonaQuestion.detect`
  (lizard row `init@120`). File: `VideoScan/VideoScan/Hallie/HallieLineageQuestion.swift:573,595,228`;
  `HalliePersonaQuestion.swift:103`.
- **Scenario:** a regex literal containing the word `get` (`/\b(?:get|fetch|…)\b/`) makes lizard emit a function named
  `get` spanning three real functions (CCN 93). After neutralising the 130 regex literals, both `get` rows disappear,
  and `detectShape` shrinks from 335 lines to a 133-line fragment. The #281 debt list and tonight's brief name functions
  that don't exist (`get`, `HalliePersonaQuestion.init`). After the refactor the ratchet will see "new" and "vanished"
  offenders that are only parse noise, and rewording one regex can "pay" debt that was never paid.
- **Pinning test:** in the complexity collector's tests, feed a 6-line Swift file whose only function contains
  `firstMatch(of: /\b(?:get|set)\b/)` and assert the report names that function and no `get`. It fails today. The fix:
  the collector neutralises regex literals before lizard (the 6-line pre-pass used tonight is in appendix A) and names functions from the `func`/`init` keyword line.

### N1007-D-Hallie-rewrite-eval-F2: P3, REAL. Ten lineage branches have no pin and one is dead (no corpus sentence, no test sentence)
- **Symbol / file:line** (all in `HallieLineageQuestion.swift`), with the test to add:
  1. `isGedcomAwareness` :761 "how do you know the family tree" → `detect("how do you know the family tree") == .gedcomAwareness`
  2. `isGedcomAwareness` :762 → `detect("what tree file are you using") == .gedcomAwareness`
  3. `isGedcomAwareness` :758 (≤3-word arm) → `detect("the gedcom") == .gedcomAwareness`
  4. `commonAncestorQuestion` :672 (pattern 9) is **dead code**, not just unpinned. Every sentence pattern 9 matches
     also contains a pattern-5 match (:668: `(nearest|closest|common|shared|most recent…) (common|shared)? ancestor
     (of|between) A and B [born YYYY]$`, unanchored at the start), and pattern 5 runs first with the same two captures.
     So "who is the common ancestor of alice and bob" is claimed by pattern 5. Checked with the port over 45
     lead × noun × tail combinations: pattern 9 never matched where pattern 5 didn't. Action: delete pattern 9 in the
     table conversion and pin the sentence to the pattern-5 result
     (`detect("who is the common ancestor of alice and bob") == .commonAncestor(a: "Alice", b: "Bob")`).
  5–10. `superlativeQuestion` :1086 media wrapper × {longest lived, latest died, earliest married, most children,
     first born in, deepest ancestor} → for example `detect("show me a photo of the person who lived the longest in the tree") == .superlative(kind: .longestLived, scope: .wholeTree, media: "photo")`
  11. `detectShape` :406 (`starting (with|from)` + tree/descend) → `detect("show the descendants starting with the smiths") == .surnameTree(surname: "smiths")`
- **Scenario:** delete any one of these lines (or reorder a rule above it) and no test and no corpus entry changes. The
  nightly replay can't see it either, because no corpus sentence uses these forms.
- **Smallest pin:** the 11 `#expect` lines above in `HallieLineageTests` (Swift Testing, pure, no fixtures). Each
  sentence was checked against the port: it lands on the named branch and on no earlier one. One exception:
  item 4's sentence lands on pattern 5 by design.

### N1007-D-Hallie-rewrite-eval-F3: P3, REAL. Seven persona branches have no pin
- **Symbol:** `HalliePersonaQuestion.detect`, `HalliePersonaQuestion.swift:173–180`.
- **Unpinned leaves:** `" you have a <kin> "`, `" you ever have <kin> "`, `" you ever have any <kin> "`,
  `" you ever have a <kin> "`, `" you ever married "`, `" you ever marry "`, `" you marry "`.
- **Scenario:** remove the `you ever have …` alternatives (for example during the table conversion) and "did you ever
  have a husband, hallie" stops being claimed. It falls to the model translator, which is the exact failure the file
  was written for (GH #184). No test goes red.
- **Pin:** add to the `HalliePersonaQuestionTests` table (line ~127, beside `("were you married", .relatives("husband"))`):
  `("did you have a brother", .relatives("brother"))`, `("did you ever have children", .relatives("children"))`,
  `("did you ever have any kids", .relatives("kids"))`, `("did you ever have a husband", .relatives("husband"))`,
  `("were you ever married", .relatives("husband"))`, `("did you ever marry", .relatives("husband"))`,
  `("did you marry", .relatives("husband"))`.

### N1007-D-Hallie-rewrite-eval-F4: P3, NEEDS-MAC. "pics"/"documents" of a superlative person route to center-tree on a non-person
- **Symbol:** `HallieLineageQuestion.centerTreeQuestion`, `HallieLineageQuestion.swift:534,558`; related vocabularies at
  `:266` (photo branch nouns), `:1082` (`mediaNoun`), `:1086` (superlative media wrapper).
- **Scenario (parser level, from the port):** "show me pics of the oldest person in the tree" matches center-tree form 2
  (`show me <X> in the tree`). X = "pics of the oldest person" passes every veto, because the noun reject list has
  `photos?|pictures?|images?` but not `pics?`, `documents?` or `papers?`, and X is exactly 5 words. Result:
  `.centerTree(person: "Pics Of The Oldest Person")`. The answer path (`HallieLineageAnswer.centerTree`, :1965–1994)
  then either declines "I don't find Pics Of The Oldest Person in the family tree", or, with exactly one fuzzy
  `HallieNameSuggestion` hit, centers the tree on an unrelated person with "I took … to mean …". The same sentence with
  "photos" correctly becomes `.superlative(.earliestBorn, .wholeTree, media: "photo")`. Second variant: "show me a pic of
  the oldest person in the tree" (6 words, so center-tree rejects it). `pic` isn't in `mediaNoun` or in the superlative
  wrapper, so the plain superlative claims it with `media: nil`, and the user gets who the oldest person is, with no
  picture. Root cause: three different media-noun vocabularies answer one question (the C01-F1 class).
- **Why NEEDS-MAC:** a lane ahead of `detect` (`HallieTurnExecutor+Conversation.swift` before :1668) may claim
  "show me pics …" first. I didn't read those lanes.
- **Pin:** `#expect(HallieLineageQuestion.detect("show me pics of the oldest person in the tree") == .superlative(kind: .earliestBorn, scope: .wholeTree, media: "pic"))`.
  It fails today with `.centerTree(person: "Pics Of The Oldest Person")`. Then run a route-level replay of the same
  sentence on the Mac.

### N1007-D-Hallie-rewrite-eval-F5: P3, NEEDS-MAC. Relationship-executor guards to pin before any split
- **Symbol:** `HallieTurnExecutor.executeRelationship`, `HallieTurnExecutor+Relationship.swift:57,113,142,214–226,311`.
- **Guards with no matching test name in `HallieRelationshipTests`** (17 tests listed; other files not searched):
  (a) :311 a chip choice nobody consumed → `invalidContinuationResult` (stale continuation);
  (b) :222–225 a chip retry that still doesn't resolve → `invalidContinuationResult`;
  (c) :113 before :142, where the People-tab overlay answers **before** the "no imported tree" decline (tree absent,
  overlay links both → answered, not declined);
  (d) :57 executor-level `people.count != 2` decline (the decoder test at :122 pins the decoder, not this guard).
- **Scenario:** an extract-function refactor that hoists the `graphIsInstalled` guard above the overlay call turns
  "how is <son> related to <owner>" with no GEDCOM loaded from answered into "I don't have an imported family tree".
  Nothing in `HallieRelationshipTests` would go red.
- **NEEDS-MAC:** grep the whole test target for (a)–(d) (the People-tab kinship tests may cover (c)). Write the missing ones first.

---

## 5. Ranked refactor plan (top 5; the M4 executes, branch only, after Rick's go)

**1. Parser oracle + back-to-back harness + coverage sensor (S–M).** Prerequisite for 2 and 3.
- Steps: plan §3 steps 1–3. Add the 18 pin sentences from F2/F3 first, as ordinary tests.
- Pins that must exist before: F2, F3.
- Risk: low (test-only). One gotcha: `String(reflecting:)` of enums with default associated values must be stable
  across builds. Compare with `==` against decoded legacy output where possible, and keep the strings only for the
  failure report.

**2. `HalliePersonaQuestion.detect` → phrase tables (S).**
- Steps: (a) `relativePatterns` (8 format strings) × `kinWords`, looped in today's nesting order (kin outer, pattern
  inner, which matters for "your family" vs "you have family"); (b) `marriedPhrases`; (c) `vitalCues` in order birth →
  age → death → origin, with the birth sub-rule kept as code; (d) oracle diff = 0.
- Pins first: F3. Today's 11 tests plus 7.
- Risk: low. The only order dependence is kin-before-married-before-vitals, which the table keeps.

**3. `HallieLineageQuestion.detectShape` → ordered `[HallieLineageRule]` (M, 2 nights).**
- Steps: plan §3 steps 2 and 4. Paste-into-closure first, declarative rows second. Then unify the three media-noun
  vocabularies into one `mediaNouns` constant used by the photo branch, `mediaNoun`, the superlative wrapper and the
  center-tree veto. **That last step is a behaviour change (F4)**: do it as its own commit with the F4 pin and an
  explicit oracle diff Rick reviews.
- Pins first: F2 (11 sentences), F4.
- Risk: medium. The order is the semantics. The coverage sensor and the oracle are the guard.

**4. `executeRelationship` extract-function split (M, 1 night, independent).**
- Steps: extract (a) `overlayRelationshipAnswer(query:inputs:pinned:context:) -> Result?` (lines 101–141);
  (b) `resolveOwnerSlot(...) -> SlotResolution?|Result` (174–198); (c) `resolveBySpellings(...)` including chip
  consumption (199–235), returning the updated `pinned` / `floating`; (d) `clarificationResult(...)` (241–288);
  (e) `notFoundResult(...)` (289–304). The loop body becomes about 20 lines; the order of calls is unchanged.
- Pins first: F5 (a)–(d), plus the existing 17 `HallieRelationshipTests`.
- Risk: medium. `pinned` and `floating` are mutated across slot iterations, so the extracted helpers must take and
  return them explicitly (`inout` is fine). Don't capture them in closures.

**5. Complexity collector: neutralise regex literals (S).**
- Steps: the 6-line pre-pass (replace `/…/` regex literals after `(`, `,`, `=`, `[`, `:` or `return` with `""`) before
  lizard; key rows on `func`/`init` names; add F1's pinning test.
- Pins first: F1.
- Risk: low. Do it **before** item 3 lands, or the ratchet reports the rule file's closures as noise.

**Backlog (one line each)**
- `centerTreeQuestion` builds 4 `try? Regex(String)` per call (:533–548). A typo would silently disable a form, and
  there's a per-call compile cost. Hoist them to `static let` with a test that they compile.
- Five "owner word" sets disagree (`possessor` :809 includes "the/this/that/of"; `namedTarget` :1336 adds
  "here/there"; `personTreeQuestion` :512; `centerTreeQuestion` :559; `commonAncestorSide` :738). These are five answers
  to "is this the owner?". Unify into one set with a test per word.
- Four kin vocabularies (`kinFragmentNouns`, `personTreeTrailingWords`, the `kinshipApposition` regex,
  `HalliePersonaQuestion.kinWords`; persona lacks uncle/aunt/cousin/niece/nephew). Unify behind one table, with an
  oracle diff.
- `detect` runs `detectShape` on the year-stripped text and re-reads generations from the unstripped text (:189). That's
  deliberate but undocumented as a rule. Give it a row in the rule table's prelude docs.
- The detection half (1,402 lines) and the answer half (`HalliePersonVitals` + `HallieLineageAnswer`, 670 lines) share
  one 2,077-line file. Split by file after item 3 (no code change).

## Not covered
- The out-of-file recognizers (statistics ×2, birthplace trail, kinship apposition) and the lanes upstream of
  `detect` in `HallieTurnExecutor+Conversation.swift`. They decide F4's route-level outcome.
- `hallie_strict_regressions.json` (not in the brief).
- Port fidelity: the Python port is a faithful transcription of the trigger regexes and veto lists. Helper results
  (`possessor`, `namedTarget`) are approximated as non-nil, which makes `reached` an upper bound. Each "not reached"
  claim is a zero over that upper bound, so it stands. The Mac oracle (plan item 1) replaces the port.

---

## Appendix A: the branch-reach port (reproduces §1b)

Run: `python3 branch_reach.py out.json` from any directory (it reads `tests/*.json` from the repo path at the top).
Regex-literal neutraliser used for §0 (6 lines):

```python
import re
def neutralise(swift_source: str) -> str:
    return re.sub(r"([(,=\[:]\s*|return\s+|\n\s+)/(?![/*])((?:\\.|[^/\n\\])+)/(?=[\s,)\]\.;]|$)",
                  lambda m: m.group(1) + '""', swift_source)
```

<details><summary>branch_reach.py (362 lines)</summary>

```python
#!/usr/bin/env python3
"""N1007: which Hallie parser branches do the four corpora reach?

A Python port of the TRIGGER of each branch in
HallieLineageQuestion.detect/detectShape and HalliePersonaQuestion.detect
(main@c86b926). Two numbers per branch:
  indep  = the branch's own trigger fires on the sentence (upper bound on reach)
  first  = the branch is the first in-file claimant in detectShape order;
           out-of-file recognizers (statistics, birthplace trail, kinship
           apposition) are OPAQUE and cannot be ordered, so `first` is
           approximate where they would have claimed first.
indep == 0 is the hard claim: no corpus sentence can reach that branch.
"""
import json, re, sys, collections

BASE = '/home/user/VideoScan/tests/'
CORPORA = ['hallie_eval_corpus.json', 'archivist_golden_answers.json',
           'hallie_interaction_corpus.json', 'hallie_live_misses_corpus.json']

def strings(node, out):
    if isinstance(node, dict):
        for k, v in node.items():
            if k in ('text', 'input') and isinstance(v, str): out.append(v)
            elif k == 'prompts' and isinstance(v, list):
                for p in v:
                    if isinstance(p, str): out.append(p)
                    else: strings(p, out)
            elif isinstance(v, (dict, list)): strings(v, out)
    elif isinstance(node, list):
        for v in node: strings(v, out)

S = lambda p, s: re.search(p, s) is not None

def normalize(t):
    s = t.lower().replace('’', "'").strip()
    while s and s[-1] in '?!.': s = s[:-1]
    return s.strip()

MEDIA = r"\b(photo|picture|portrait|image|video|clip|movie|footage|film|snapshot)s?\b"
YEARB = r"\s*\b(?:before|until|till|up to|as far back as|as far as|to)\s+(?:the\s+)?(\d{4})s?\b"
INTERROG = r"\b(?:did|do|does|have|has|had)\s+(?:we|you|i|they)\s+(?:only\s+|already\s+|ever\s+|just\s+)?(?:get|got|gotten|fetch(?:ed)?|download(?:ed)?|pull(?:ed)?|import(?:ed)?|grab(?:bed)?|load(?:ed)?|have)\b"
SEAM = r"\s*(?:,\s*(?:and|but|or)\s+|\s+(?:and|but)\s+|[?;])\s*"

def fetch_clause(c):
    if not (S(r"\b(?:get|fetch|download|pull|import|grab|update|refresh|expand|extend|deepen)\b", c) and
            S(r"\b(?:family ?search|gedcom|(?:family )?tree|ancestors|ancestry|generations)\b", c)): return None
    if S(INTERROG, c): return None
    if 'familysearch' in c or 'family search' in c: return 'B01-familysearch'
    if S(r"\b(?:get|fetch|download|pull|import|grab) (?:more (?:of )?)?(?:the |my |our |a )?(?:whole |entire |full |bigger |deeper |updated |new |latest )?(?:family )?(?:tree|gedcom|ancestors|ancestry)\b", c): return 'B01-verb-tree'
    if S(r"\b(?:more|deeper|further|older) (?:generations|ancestors)\b", c): return 'B01-more-gens'
    if S(r"\b(?:update|refresh|expand|extend|deepen) (?:the |my |our )?(?:family )?tree\b", c): return 'B01-update-tree'
    return None

def b01(l):
    for c in re.split(SEAM, l):
        r = fetch_clause(c)
        if r: return r

def b02(l):
    if not (S(INTERROG, l) and S(r"\b(?:gedcom|family ?search|(?:family )?tree|ancestors|ancestry)\b", l)): return None
    sur = S(r"\bthe ([a-z][a-z'-]+) (?:line|side|family|branch|lineage)\b", l) or S(r"\b(?:for|of|from) the ([a-z][a-z'-]+s)\b", l)
    per = S(r"\b(?:from|for)\s+((?:[a-z][a-z'-]*\s*){1,3})", l)  # approx: stop-word filter not applied
    return 'B02-provenance' if (sur or per) else None

def b03(l):
    if 'gedcom' in l:
        cues = ["what is", "what's", "whats", "explain", "where", "which file", "come from", "source",
                "how do you", "tell me about", "mean", "loaded", "using"]
        if any(c in l for c in cues): return 'B03-gedcom-cue'
        if len(l.split(' ')) <= 3: return 'B03-gedcom-short'
        return None
    if S(r"\bwhere (?:does|did|is) (?:your|the) (?:family )?tree (?:come from|from|loaded)", l): return 'B03-tree-from'
    if S(r"\bhow do you know (?:the|our|my) family tree\b", l): return 'B03-how-know'
    if S(r"\bwhat (?:family )?tree (?:file )?(?:are you|do you) (?:using|reading)\b", l): return 'B03-what-file'

N = r"([a-z0-9(][a-z0-9 .,'()-]*?)"
CA = [
 r"\b(?:how|so how)\s+(?:is|are|was|were)\s+"+N+r"\s+(?:and|&)\s+"+N+r"\s+(?:related|connected|linked|kin)\b",
 r"\b(?:how|so how)\s+(?:is|are|was|were)\s+"+N+r"\s+related\s+to\s+"+N+r"(?:\s+(?:by blood|at all|somehow))?\s*$",
 r"^(?:so\s+)?(?:is|are|was|were)\s+"+N+r"\s+(?:and|&)\s+"+N+r"\s+(?:related|connected|kin|cousins|blood relatives|relatives)(?:\s+(?:at all|somehow|by blood))?\s*$",
 r"^(?:so\s+)?(?:is|are|am|was|were)\s+"+N+r"\s+related\s+to\s+"+N+r"(?:\s+(?:by blood|at all|somehow))?\s*$",
 r"\b(?:nearest|closest|common|shared|most recent|latest|recent|first)\s+(?:common\s+|shared\s+)?ancestors?\s+(?:of|between|for|shared by)\s+"+N+r"\s+(?:and|&)\s+"+N+r"(?:\s+(?:born|b\.)\s+(?:in\s+)?\d{4})?\s*$",
 r"\b(?:do|did|does)\s+"+N+r"\s+(?:and|&)\s+"+N+r"\s+(?:share|have)\s+(?:an?\s+|any\s+)?(?:common\s+|shared\s+)?ancestors?\b",
 r"\bwhat\s+(?:do|does|did)\s+"+N+r"\s+(?:and|&)\s+"+N+r"\s+have\s+in\s+common\s+(?:ancestrally|genealogically|in the (?:family )?tree|as ancestors)\b",
 r"\b"+N+r"\s+(?:and|&)\s+"+N+r"'?s?\s+(?:nearest\s+|closest\s+)?(?:common|shared)\s+ancestors?\b",
 r"\bwho\s+(?:is|was)\s+(?:the\s+)?(?:nearest\s+|closest\s+|most recent\s+)?(?:common|shared)\s+ancestor\s+(?:of|between)\s+"+N+r"\s+(?:and|&)\s+"+N+r"(?:\s+(?:born|b\.)\s+(?:in\s+)?\d{4})?\s*$",
 r"\bwhere\s+(?:do|does|did)\s+"+N+r"(?:'s)?\s+(?:and|&)\s+"+N+r"(?:'s)?\s+(?:lines?|trees?|famil(?:y|ies)|ancestr(?:y|ies))\s+(?:meet|cross|join|connect|converge)\b",
]
OUR = [
 r"\bour\s+(?:nearest\s+|closest\s+|most recent\s+|latest\s+|recent\s+|first\s+)?(?:common|shared)\s+ancestors?\b",
 r"\b(?:common|shared)\s+ancestors?\s+(?:of|between|for|shared by)\s+(?:the two of us|us two|us both|both of us|us)\b",
 r"\b(?:how|so how)\s+(?:are|were)\s+we\s+(?:related|connected|linked|kin)\b",
 r"^(?:so\s+)?(?:are|were)\s+we\s+(?:related|connected|kin|cousins|blood relatives|relatives)(?:\s+(?:at all|somehow|by blood|to each other))?\s*$",
 r"\bdo\s+we\s+(?:share|have)\s+(?:an?\s+|any\s+)?(?:common\s+|shared\s+)?ancestors?\b",
 r"\bwhat\s+do\s+we\s+have\s+in\s+common\s+(?:ancestrally|genealogically|in the (?:family )?tree|as ancestors)\b",
 r"\bwhere\s+do\s+our\s+(?:lines?|trees?|famil(?:y|ies)|ancestr(?:y|ies))\s+(?:meet|cross|join|connect|converge)\b",
]
NOBODY = {"they","them","we","us","you","he","she","it","family","everyone","anyone","people","each other"}
OWNER = {"me","i","myself","my","mine"}
def ca_side(raw):
    s = raw.strip()
    if s.startswith('the ') and len(s) > 4: return False
    for lead in ["my wife ", "my husband "]:
        if s.startswith(lead) and len(s) > len(lead): s = s[len(lead):]
    s = re.sub(r"'s?$", "", s)
    if s in OWNER: return 'owner'
    if s in NOBODY or not s: return False
    return 'name' if len(s.split(' ')) <= 8 else False

def b04(l):
    if S(MEDIA, l): return None
    m = re.search(r"\b(?:how|so how)\s+(?:are|were|am|is)\s+(we|us|i|me)\s+related(?:,?\s+if\s+at\s+all,?)?\s+to\s+([a-z0-9(][a-z0-9 .,'()-]*?)(?:\s+(?:by blood|at all|somehow))?\s*$", l)
    if m and ca_side(m.group(2)) == 'name': return 'B04-we-related-to-X'
    for i, p in enumerate(CA):
        m = re.search(p, l)
        if not m: continue
        a, b = ca_side(m.group(1)), ca_side(m.group(2))
        if not a or not b: continue
        if a == 'owner' and b == 'owner': return None
        return 'B04-pair-p%d' % (i + 1)
    for i, p in enumerate(OUR):
        if S(p, l): return 'B04-our-p%d' % (i + 1)

TREEW = r"(?:the\s+)?(?:family\s+)?tree(?:\s+view)?"
def b05(l):
    s = re.sub(r"^(?:(?:please|hallie|ok|okay|can you|could you|would you|will you|now|just),?\s+)+", "", l)
    s = re.sub(r"\s+(?:please|for me|now)\s*$", "", s)
    raw = tag = None
    m = re.search(r"^(?:re)?(?:center|centre|focus|zoom(?:\s+in)?)\s+(?:" + TREEW + r"\s+)?(?:on|to|around)\s+(.+)$", s)
    if m: raw, tag = m.group(1), 'B05-center-on'
    else:
        m = re.search(r"^(?:show(?:\s+me)?|open|find|display|highlight|select|locate|pull\s+up|bring\s+up|look\s+up)\s+(.+?)\s+(?:in|on)\s+" + TREEW + r"$", s)
        if m: raw, tag = m.group(1), 'B05-show-in-tree'
        else:
            m = re.search(r"^(?:take\s+me|go|jump|navigate|move)\s+(?:over\s+)?to\s+(.+?)(\s+(?:in|on)\s+" + TREEW + r")?$", s)
            if m:
                if m.group(2) is None and not s.startswith('take me'): return None
                raw, tag = m.group(1), 'B05-take-me-to'
    if raw is None: return None
    name = re.sub(r"\s+(?:in|on)\s+" + TREEW + r"$", "", raw.strip())
    if not re.search(r"^[a-z][a-z .'-]*$", name) or re.search(r"'s?\b", name) or len(name.split(' ')) > 5: return None
    if re.search(r"^(?:the|a|an|this|that|these|those|my|our|your|his|her|their)\s", name): return None
    if re.search(r"\b(?:videos?|photos?|pictures?|clips?|movies?|footage|films?|images?|catalog|tab|window|screen|page|map|frame|files?|folders?|track|player|people|family)\b", name): return None
    return tag

SUPW = r"\b(?:oldest|eldest|youngest|earliest|latest|first|last|longest|most|deepest|farthest|furthest|distant|largest|biggest|recent(?:ly)?|how far back)\b"
def sup_kind(t):
    if not S(SUPW, t): return None
    if S(r"\b(?:oldest|eldest|youngest|first|last)\s+(?:born\s+)?(?:son|daughter|child|kid|brother|sister|sibling|grand\w+|boy|girl|cousin|uncle|aunt|nephew|niece|wife|husband|marriage)\b", t): return None
    if S(r"\b(?:first|earliest|oldest)\b.*\bborn\s+in\s+(?:the\s+)?([a-z][a-z .'-]+?)\s*$", t): return 'firstBornIn'
    if (S(r"\b(?:deepest|farthest|furthest|most distant|remotest)\b[a-z' ]*\bancestors?\b", t) or
        S(r"\bancestors?\b.*\b(?:farthest|furthest|deepest|most distant)\s+back\b", t) or
        S(r"\bhow far back\b.*\b(?:go|goes|reach|reaches)\b", t)): return 'deepestAncestor'
    if S(r"\b(?:lived?|living)\s+(?:the\s+)?longest\b|\blongest[- ](?:lived|living|life)\b|\b(?:oldest|greatest|highest)\s+age\b|\bmost\s+years\b", t): return 'longestLived'
    if S(r"\b(?:most\s+recent(?:ly)?|last|latest)\b[a-z' ]*\b(?:died|death|passed|die)\b|\b(?:died|passed(?: away)?)\s+(?:most\s+recently|last|latest)\b", t): return 'latestDied'
    if S(r"\b(?:earliest|first|oldest)\b[a-z' ]*\b(?:married|marriage|marry|wedding|wed)\b|\b(?:married|wed)\s+(?:first|earliest)\b", t): return 'earliestMarried'
    if S(r"\bmost\s+(?:children|kids|sons|daughters|offspring|descendants)\b|\b(?:largest|biggest)\s+(?:family|brood|household)\b", t): return 'mostChildren'
    if S(r"\byoungest\b|\b(?:latest|most\s+recent(?:ly)?|last)\s+(?:born|birth)\b|\bborn\s+(?:last|most\s+recently|latest)\b", t): return 'latestBorn'
    if S(r"\boldest\b|\beldest\b|\bearliest\s+(?:birth|born)\b|\bborn\s+(?:first|earliest)\b|\bfirst\s+(?:person\s+|one\s+)?born\b|\bearliest\b[a-z' ]*\bbirth\b", t):
        if (S(r"\b(?:persons?|people|members?|relatives?|ancestors?|forebears?|ones?|man|men|woman|women|male|female|birth|born|individuals?|humans?|guys?|lady|family|tree|surname|named|lineage|line)\b", t)
                or S(r"\b(?:oldest|eldest)\s+[a-z]+s?\s*$", t)): return 'earliestBorn'
    return None

def b08(l):
    m = re.search(r"\b(photo|picture|portrait|image|video|clip|movie|footage|film|snapshot)s?\s+of\s+(.+)$", l)
    if m:
        ph = m.group(2).strip()
        if S(MEDIA, ph): return None
        k = sup_kind(ph)
        return ('B08-media-' + k) if k else None
    if S(MEDIA, l): return None
    k = sup_kind(l)
    return ('B08-' + k) if k else None

def b09_11(l):
    m = re.search(r"\b(?:photo|picture|portrait|image|pic|document|doc|paper)s?\s+of\s+([a-z][a-z .'-]+?(?:\s*\([^)]*\)|\s+(?:who\s+)?(?:born|b\.|died|d\.)\s+(?:in\s+)?\d{4})?)\s*$", l)
    if m and S(r"\b(?:show|see|display|view|got|have|any|there|all|every)\b", l) and not S(r"\b(?:and|with)\b|&|,", m.group(1)):
        return 'B09-photo-of-X'
    m = re.search(r"\bwhat\s+(?:photo|picture|pic|document|doc|paper)s?\s+(?:do|have)\s+(?:we|you|i)\s+(?:have|got)\s+(?:for|of|on|about)\s+([a-z][a-z .'-]+?)\s*\??\s*$", l)
    if m and not S(r"\b(?:and|with)\b|&|,", m.group(1)): return 'B10-what-photos-for-X'
    if S(r"\b(his|her|their)\s+(?:photo|picture|portrait|image)s?\s*$", l) and S(r"\b(?:show|see|display|view|got|have|any|find|there)\b", l):
        return 'B11-pronoun-photo'

def b12_14(l):
    m = re.search(r"^describe\s+(?:the\s+)?([a-z][a-z .'-]+?)(?:'s?\s+(?:physical\s+)?(?:appearance|personality|character|looks|traits))?(?:\s+(?:and|as)\b.*)?$", l)
    if m and m.group(1).strip(): return 'B12-describe-X'
    if S(r"\bwhat (?:was|is|were) ([a-z][a-z .'-]+?) like\b", l): return 'B13-what-was-X-like'
    m = re.search(r"\b([a-z][a-z .'-]+?)'s\s+(?:physical\s+)?(?:appearance|personality|character|looks)\b", l)
    if m:
        toks = m.group(1).split(' ')
        leads = {"tell","me","about","show","please","hallie","describe","us","what","was","is","the"}
        while toks and toks[0] in leads: toks.pop(0)
        if toks: return 'B14-Xs-appearance'

FAMW = r"\b(?:famil\w*|ancest\w*|roots?|line|lineage|links?|side|heritage|people|tree)\b"
def b15_18(l):
    tr = re.sub(r"\s+as far (?:back )?as (?:you can(?: go)?|possible|it goes|we can)\s*$", "", l)
    m = re.search(r"\b(?:trace|follow|find|walk|take)\b(.*?)\b(?:back|down|up)(?:\s+to\s+([a-z][a-z .'-]*))?$", tr)
    if m and S(FAMW, m.group(1)): return 'B15-trace-back' + ('-to-place' if m.group(2) else '')
    m = re.search(r"\b(?:trace|follow|walk)\b(.*?)\bto\s+([a-z][a-z .'-]*)$", tr)
    if m and S(FAMW, m.group(1)): return 'B16-trace-to-place'
    if S(r"\btrace\b(.*?)\b(?:ancestors|ancestry|family|roots|line|lineage|links?|side|heritage|people)\b", tr): return 'B17-trace-family-word'
    if (S(r"\bwhere (?:did|does|do) (?:the |our |my |we |us )?(?:family|ancestors|people)?\s*(?:originally )?come from\b", l)
            or S(r"\bwhat country (?:did|does|is) (?:the |our |my )?family (?:come )?from\b", l)): return 'B18-where-from'

PTW = set("and or plus including with also his her their the all brother brothers sister sisters sibling siblings parent parents mother father mom dad ma pa grandparent grandparents grandmother grandfather grandma grandpa child children kid kids son sons daughter daughters spouse spouses wife husband family relatives relations immediate close aunts uncles cousins in-laws etc".split())
def b19(l):
    s = re.sub(r"^(?:(?:please|hallie|ok|okay|so|can you|could you|would you|will you),?\s+)+", "", l)
    s = re.sub(r"\s+(?:please|for me)\s*$", "", s)
    m = re.search(r"^(?:(?:tell me about|tell me|tell us about|show me|show|give me|describe|what is|what's|whats|about|open|display|i want to see|let me see|let's see|lets see)\s+)?(?:(my|our)|([a-z][a-z .-]*?(?:'[a-z]+)?)'s)\s+(?:own\s+|whole\s+|full\s+|entire\s+)?family\s+tree\b(.*)$", s)
    if not m: return None
    trailing = re.sub(r"[,;:.!?()]", " ", m.group(3)).split()
    if not all(w in PTW for w in trailing): return None
    if m.group(1): return 'B19-person-tree-mine'
    name = (m.group(2) or '').strip()
    if not name or len(name.split(' ')) > 5: return None
    if re.search(r"^(?:the|a|an|this|that|these|those|his|her|their|your|whose|which|what)(?:\s|$)", name): return None
    if re.search(r"\b(?:family|families|tree|catalog|video|photo|people)\b", name): return None
    return 'B19-person-tree-named'

KIN = set("father dad daddy papa mother mom mum mama parents parent brother brothers sister sisters siblings sibling son sons daughter daughters children child kids kid husband wife spouse spouses uncle uncles aunt aunts cousin cousins nephew nephews niece nieces".split())
SENT = set("who whom whose what where when how why which is was are were did do does can could would tell me us about show find list give name identify have has had of for with to in on i we you".split())
SPSTOP = set("my our their they them him it we you i us his her your its anyone anybody someone somebody everyone everybody people".split())
LEAD = r"^(?:(?:and|also|then|so|ok|okay|hallie|please),?\s+)*"
def b21(l):
    for i, p in enumerate([LEAD + r"(?:who|whom)\s+did\s+(?:(he|she)|([a-z][a-z .'-]*?))\s+(?:marry|wed)\s*\??\s*$",
                           LEAD + r"(?:who|whom)\s+(?:was|is|were)\s+(?:(he|she)|([a-z][a-z .'-]*?))\s+(?:married|wed|wedded)\s+to\s*\??\s*$"]):
        m = re.search(p, l)
        if not m: continue
        if m.group(1): return 'B21-spouse-%s-pronoun' % ('didMarry' if i == 0 else 'marriedTo')
        w = (m.group(2) or '').strip().split()
        if w and len(w) <= 5 and not any(x in SENT for x in w) and not any(x in SPSTOP for x in w):
            return 'B21-spouse-%s-named' % ('didMarry' if i == 0 else 'marriedTo')
        return None
    m = re.search(LEAD + r"(?:tell\s+(?:me|us)\s+(?:(?:all|more|everything)\s+)?about|what\s+do\s+you\s+know\s+about)\s+(his|her)\s+([a-z]+)\s*\??\s*$", l)
    if m and m.group(2) in KIN: return 'B21-about-pronoun-kin'
    m = re.search(LEAD + r"(?:(?:who|what)\s+(?:are|were|is|was)\s+(?:all\s+(?:of\s+)?)?(?:the\s+)?(?:names?\s+of\s+)?|(?:list|name|identify|give\s+me|show\s+me|tell\s+me)\s+(?:all\s+(?:of\s+)?)?(?:the\s+)?(?:names?\s+of\s+)?)(?:all\s+(?:of\s+)?)?(?:(his|her)|([a-z][a-z .'-]*?)'s?)\s+([a-z]+)\s*\??\s*$", l)
    if m and m.group(3) in KIN:
        if m.group(1): return 'B21-named-kin-sentence-pronoun'
        p = (m.group(2) or '').strip(); w = p.split()
        if w and len(w) <= 5 and not any(x in SENT for x in w) and p not in ("my","our","his","her","their") and not p.startswith('the '):
            return 'B21-named-kin-sentence-named'
    m = re.search(r"^(?:(?:and|also|then|now|so|ok|okay|hallie|please|what about|how about|and what about|and how about),?\s+)*(?:(my|our)|(his|her|their)|([a-z][a-z .'-]*?)'s?)\s+(?:own\s+)?([a-z]+)\s*(?:,?\s*(?:please|hallie|then))?$", l)
    if m and m.group(4) in KIN:
        if m.group(1): return 'B21-fragment-mine'
        if m.group(2): return 'B21-fragment-pronoun'
        p = (m.group(3) or '').strip(); w = p.split()
        if w and len(w) <= 5 and not any(x in SENT for x in w) and not p.startswith('the '): return 'B21-fragment-named'
    m = re.search(r"(?:^|\s)(?:(my|our)|([a-z][a-z .'-]*?)'s?)\s+(?:(maternal|paternal|mother'?s|father'?s)\s+)?((?:(?:\d+|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|twelfth)(?:st|nd|rd|th)?[- ]?(?:x|times)?[- ]?great[- ]?|(?:great[- ]?)+)?grand[a-z]+)(?:\s+on\s+(?:his|her|my|our|their|the)\s+(paternal|maternal|father'?s|mother'?s)\s+side)?\b", l)
    if m:
        rest = l[m.end():].strip()
        if rest == '' or S(r"^(?:please|hallie|thanks|for me)\b", rest):
            words = m.group(4).replace('-', ' ').split()
            greats = words.count('great')
            nums = [w for w in words[:-1] if re.search(r"\d", w) or w in ('first','second','third','fourth','fifth','sixth','seventh','eighth','ninth','tenth','twelfth')]
            g = greats if not nums else 3
            side = '-side' if (m.group(3) or m.group(5)) else ''
            return ('B21-grand-kinship' if g <= 2 else 'B21-grand-deepAncestor') + side

def b22_30(l, tr):
    if S(r"(?:^|\s)(.*?)\b(maternal|paternal|mother'?s|father'?s)\s+(?:line|side|ancestors|ancestry|lineage)\b(.*)$", l): return 'B22-maternal-paternal-line'
    if S(r"(?:^|\s)(.*?)\b(?:ancestors|ancestry|pedigree)\b(.*?\b(\d+|[a-z]+)\s+generations?)", l): return 'B23-ancestors-N-generations'
    m = re.search(r"family tree (?:for|of|from|starting (?:with|from|at)) (the )?([a-z][a-z .'-]+?)(\s+(?:all the way |as far )?back(?:wards?)?(?:\s+to\s+(?:the\s+)?(?:\d{4}s?|[a-z]+))?)?\s*$", tr)
    if m and (m.group(3) is not None or tr != l): return 'B24-tree-from-X-back' + ('-surname' if m.group(1) else '-person')
    if S(r"family tree (?:for|of|starting (?:with|from)) (?:the )?(?:current |present |whole |entire |modern |immediate |original |early )?([a-z][a-z'-]+)(?:'s?)?(?:\s+family|\s+clan|\s+side)?\s*$", l): return 'B25-family-tree-for-surname'
    if S(r"\bstarting (?:with|from) (?:the )?([a-z][a-z'-]+)(?:\s+family|\s+clan)?\s*$", l) and ('tree' in l or 'descend' in l): return 'B26-starting-with-surname'
    if S(r"\bthe ([a-z][a-z'-]+) family(?:'s)? tree\b", l): return 'B27-the-X-family-tree'
    if S(r"^(?:(?:hallie|please|ok|okay|so),?\s+)*(?:tell (?:me|us) about|what about|who (?:are|were)|describe|show (?:me|us)|about)\s+the\s+([a-z][a-z'-]+)\s+(?:family|clan)\s*\??\s*$", l): return 'B28-about-the-X-family'
    m = re.search(r"\b(?:videos?|films?|footage|movies?|clips?|home movies)\s+of\s+([a-z][a-z .'-]+?)\s*$", l)
    if m and m.group(1).strip() and len(m.group(1).split()) <= 5: return 'B29-videos-of-X'
    if S(r"\b(his|her|their)\s+(?:videos?|films?|footage|movies?|clips?|home movies)\s*$", l) and S(r"\b(?:show|see|play|find|got|have|any|there)\b", l): return 'B30-pronoun-videos'

ORDER = ['B01', 'B02', 'B03', 'B04', 'B05', 'OPAQUE-stats', 'OPAQUE-trail', 'B08', 'B09-11', 'B12-14',
         'B15-18', 'B19', 'OPAQUE-apposition', 'B21', 'B22-30']

def shape_hits(l):
    tr = re.sub(r"\s+as far (?:back )?as (?:you can(?: go)?|possible|it goes|we can)\s*$", "", l)
    return [(k, f) for k, f in [('B01', b01(l)), ('B02', b02(l)), ('B03', b03(l)), ('B04', b04(l)), ('B05', b05(l)),
                                ('B08', b08(l)), ('B09-11', b09_11(l)), ('B12-14', b12_14(l)), ('B15-18', b15_18(l)),
                                ('B19', b19(l)), ('B21', b21(l)), ('B22-30', b22_30(l, tr))] if f]

def lineage(text):
    l = normalize(text)
    if not l: return [], []
    yb = re.search(YEARB, l)
    pre = []
    if yb and 1000 <= int(yb.group(1)) <= 2100:
        pre.append('Y0-yearBound-peeled')
        l = re.sub(YEARB, '', l).strip()
    return pre, shape_hits(l)

# --- Persona (HalliePersonaQuestion.detect), oracle = always false -------------
SECOND = {"you", "your", "yours", "yourself"}
FIRST = {"i", "i'm", "me", "my", "mine", "myself", "we", "us", "our", "ours"}
SEARCH = set("show find search play reveal open list count video videos clip clips photo photos picture pictures footage tape tapes recording recordings file files catalog archive transcript movie movies film films".split())
REQ = ["can you", "could you", "would you", "will you", "do you know", "did you find", "have you got", "are you able to"]
PKIN = "mother mom mum mama father dad daddy papa parents grandmother grandma grandfather grandpa grandparents husband wife spouse children kids son sons daughter daughters brother brothers sister sisters siblings family ancestors".split()
def persona(q):
    if len(q) > 200: return None
    t = q.strip().lower().replace('’', "'").strip("?.!,;: ")
    if not t: return None
    for n in ["hallie mae", "hallie"]:
        if t.endswith(", " + n) or t.endswith(" " + n):
            t = t[: -(len(n) + (2 if t.endswith(", " + n) else 1))]; break
    w = [x for x in re.split(r"[^a-z0-9']+", t) if x]
    while w and w[0] in {"hey", "hi", "ok", "okay", "so", "please"}: w.pop(0)
    if w and w[0] == 'hallie':
        w.pop(0)
        if w and w[0] == 'mae': w.pop(0)
    if not w: return None
    if any(len(x) == 4 and x.isdigit() and 1900 <= int(x) <= 2100 for x in w): return 'G-year'
    if set(w) & SEARCH: return 'G-search-word'
    if not any(x in SECOND for x in w): return None
    typed = [x for x in re.split(r"[^A-Za-z0-9']+", q) if x][1:]
    if any(x[:1].isupper() and x.lower() not in ("hallie", "mae", "i", "i'm") for x in typed): return 'G-typed-name'
    rem = list(w); op = ' ' + ' '.join(rem) + ' '
    for lead in REQ:
        if op.startswith(' %s ' % lead): rem = rem[len(lead.split()):]; break
    op = ' ' + ' '.join(rem) + ' '
    if op.startswith(' tell me ') or op.startswith(' tell us '): rem = rem[2:]
    if set(rem) & FIRST: return 'G-first-person'
    if not any(x in SECOND for x in rem): return 'G-request-lead-ate-you'
    p = ' ' + ' '.join(rem) + ' '
    for k in PKIN:
        for pat, tag in [(" your %s ", 'your'), (" your %s's ", 'your-poss'), (" you have %s ", 'have'),
                         (" you have any %s ", 'have-any'), (" you have a %s ", 'have-a'), (" you ever have %s ", 'ever-have'),
                         (" you ever have any %s ", 'ever-have-any'), (" you ever have a %s ", 'ever-have-a')]:
            if pat % k in p: return 'P-relatives-' + tag
    for pat in [" you married ", " you ever married ", " you ever marry ", " you marry "]:
        if pat in p: return 'P-married' + pat.strip().replace(' ', '-')
    if any(c in p for c in [" born ", " birthplace ", " birthday ", " birth date ", " date of birth "]):
        if any(c in p for c in [" birthday ", " birth date ", " date of birth "]): return 'P-birthdate-word'
        o = rem[0] if rem else ''
        if o == 'when' or any(c in p for c in [" what year ", " what day ", " what date "]): return 'P-birthdate-when'
        if o == 'where' or any(c in p for c in [" what town ", " what city ", " what country ", " what place ", " what state ", " birthplace "]): return 'P-birthplace'
        return 'P-birthdate-default'
    if any(c in p for c in [" how old ", " your age ", " age are you "]): return 'P-age'
    if any(c in p for c in [" die ", " died ", " death ", " dead ", " alive ", " pass away ", " passed away ", " still living ", " still around "]): return 'P-death'
    if any(c in p for c in [" where are you from ", " where do you come from ", " where did you come from ", " where did you grow up ",
                            " where were you raised ", " where are you originally from ", " where you grew up ", " where did you live ", " where do you live "]): return 'P-origin'
    return 'G-no-ask'

if __name__ == '__main__':
    seen = {}
    for f in CORPORA:
        out = []; strings(json.load(open(BASE + f)), out)
        for s in out: seen.setdefault(s, set()).add(f.split('.')[0])
    print('unique sentences', len(seen))
    indep = collections.Counter(); first = collections.Counter(); pers = collections.Counter()
    by_corpus = collections.defaultdict(collections.Counter)
    for s, cs in seen.items():
        pre, hits = lineage(s)
        for p in pre: indep[p] += 1
        for k, f in hits:
            indep[f] += 1
            for c in cs: by_corpus[f][c] += 1
        if hits: first[hits[0][1]] += 1
        pr = persona(s)
        if pr: pers[pr] += 1
    json.dump({'indep': indep, 'first': first, 'persona': pers,
               'by_corpus': {k: dict(v) for k, v in by_corpus.items()}},
              open(sys.argv[1] if len(sys.argv) > 1 else '/dev/stdout', 'w'), indent=1, sort_keys=True)
```

</details>
