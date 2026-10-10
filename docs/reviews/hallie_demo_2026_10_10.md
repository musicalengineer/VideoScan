# Hallie take-two: tool-using agent vs today's Hallie (judged 2026-10-10)

Judge: Claude (Fable 5.1), read-only. Suite `tests/hallie_acceptance_v1.json`
sha256 `ebd68308c852166227f2389f8987d1a5260f4eab9095e93573990bc047b1d2fc` — **verified, matches**.
Expected answers: `scripts/hallie_demo/hallie_baseline.json`; bars: `scripts/hallie_demo/scoring.md`.
Every agent number that was spot-checked was re-run through `scripts/hallie_demo/tools.py`
against the same snapshot (catalog gen 3189, tree gen-20260924T222812-b7d9).

Lanes:

- **H** — today's Hallie, headless shell, Debug build e346a58f4, composer `qwen3.8:27b-mlx`
  (`~/Library/Logs/VideoScan/hallie-eval/acceptance-v1-20261010.jsonl`, 33 turns, 183 s).
- **A1** — Sonnet agent in Claude Code, tool kit with media text REDACTED.
- **A2** — Sonnet agent in Claude Code, transcripts visible.

Scoring: PASS = 1, PARTIAL = 0.5, FAIL = 0; a category passes only at its bar.

## Scorecard

| category (bar) | H as run | H, outage turns removed | A1 (redacted) | A2 (visible) |
|---|---|---|---|---|
| no_bluff (100%, zero wrong-subject) | 0/4 = 0% ❌ | 0/1 = 0% ❌ | 4/4 = 100% ✅ | 4/4 = 100% ✅ |
| stats (100% exact, basis stated) | 1/6 = 17% ❌ | 1/3 = 33% ❌ | 5/6 = 83% ❌ | 4.5/6 = 75% ❌ |
| multi_hop (≥ 80%) | 0/4 = 0% ❌ | 0/0 — ❌ | 3/4 = 75% ❌ | 3.5/4 = 88% ✅ |
| conversation (≥ 80% of turns) | 1.5/6 = 25% ❌ | 1.5/4 = 38% ❌ | 6/6 = 100% ✅ | 6/6 = 100% ✅ |
| loose_phrasing (≥ 90%) | 4/8 = 50% ❌ | 4/8 = 50% ❌ | 7.5/8 = 94% ✅ | 8/8 = 100% ✅ |
| story (every row cited, nothing invented) | 3/5 ❌ | 3/5 ❌ | 5/5 ✅ | 5/5 ✅ |
| **all turns** | **9.5/33 = 29%** | **9.5/21 = 45%** | **30.5/33 = 92%** | **31/33 = 94%** |
| wrong-subject answers | 3 | 3 | 0 | 0 |
| bluffs (confident answer to a different question) | 2 | 2 | 0 | 0 |
| bad declines (data existed) | 2 | 2 | 0 | 0 |
| uncited / tool-unsupported claims | n/a | n/a | 3 minor | 2 minor |

The pattern grader (`hallie_eval.py grade --show 40`) agrees on H: 9 clean of 33 (27%), 24 flagged
(22 missing_required_match, 6 forbidden_text, 3 declined_expected_answer).

**Confound in H, stated up front.** 12 of H's 33 turns are the stock line "I'm having trouble
reaching my language helper just now" (`outcome=interpretation-failed`, no route): nb-02/03/04,
st-02/03/04, all four multi_hop rows, cv-01-t3/t4. That is the composer being unreachable in
the headless run, not Hallie's brain. The second H column removes those turns; H still fails
every bar, and the live demo answers in the baseline for the same questions (Bonnie: declined
three times; "111 people named Nana"; Hudson count: etymology; Hudsons at Thanksgiving:
"not mentioned anywhere"; "tell me about the hudsons": whole-tree summary) show the same
failure modes with the composer up.

**Caveat on the agent lanes.** A1/A2 ran as a Sonnet agent inside Claude Code with no latency
or cost budget, unlimited tool calls, and the tool kit's JSON in full. They measure the brain
(does a tool-using model answer right from this data?), not the plumbing (local model, response
time, cost, the app's routing). Nothing here says a local 27B model would do this.

## Verdict

On the brain, this is a huge leap: the agent lanes went from Hallie's 29% (45% with the outage
removed) to 92–94%, with zero wrong-subject answers, zero bluffs and every category except
stats at or over its bar, versus Hallie clearing none. It is not flawless: both agent lanes
missed the stats bar on the Thanksgiving-hours row (and A2 on the decade row) by counting
audio-only files as "videos" — the tool's `kind` default is `any`, and the agent did not notice
the question said video — so the demo's "no_bluff AND stats flawless" success criterion is half
met. The fix is a one-line tool default plus a stream-type line in every count, not a model
change; with that, the stats rows re-run would almost certainly pass.

## Per-row grades

Flags: WS = WRONG-SUBJECT, UF = UNVERIFIED-FACT (not supported by the cited tool result),
BL = BLUFF, GD = GOOD-DECLINE, OUT = composer outage (infrastructure, not brain).

### no_bluff

| id | H | A1 | A2 | notes |
|---|---|---|---|---|
| ac-nb-01 tell me about Bonnie | FAIL (declined; data existed) | PASS | PASS | Both agents: Donna's older sister per told note, confirmed on 2011_Reckards_Hudson_Christmas, cited. A2 over-hedges ("whether that's the same Bonnie isn't settled") — honest, not wrong. |
| ac-nb-02 find nana | FAIL OUT (live: "111 people named Nana" = invented, BL) | PASS GD | PASS GD | Both ask which grandmother: Muriel Lamb @I4@ / Mary Christina O'Connor @I7@; duplicate @I5@ correctly excluded. Verified via resolve_person. |
| ac-nb-03 Donna's great-grandfather, Hudson side | FAIL OUT | PASS | PASS | Both: William Hudson b. 1877 @IB15@, plus Gordon MacGregor @IB13@ on the same paternal side. Both print "1877–1930"; the tree says died "after 1930 before 1950" — the tool flattens the qualifier (see tool gaps). |
| ac-nb-04 find videos of bonnie (control) | FAIL OUT (live: GOOD) | PASS | PASS | One file, confirmed tag, note quoted, cited. |

### stats

| id | H | A1 | A2 | notes |
|---|---|---|---|---|
| ac-st-01 surname Hudson count | FAIL BL (etymology) | PASS | PASS | 11 primary / 13 incl. alternates, 1380–1959, basis stated. Verified. |
| lv261010-014 count surname hudson | FAIL BL (etymology) | PASS | PASS | Same; A1 adds tree size 39,250 (verified). |
| ac-st-02 Donna videos 1980s | FAIL OUT | PASS | PASS | A1 gives both bases (44/64, 33 h; confirmed-only 2/3; 385 undated excluded). A2 gives 44/64/385 with the default basis named. All verified. |
| ac-st-03 decade with most video | FAIL OUT | PASS | PARTIAL | A1 ran `kind=video`: 1990s 153 h/254, 2000s 68 h, 2020s 2,272 files/17 h, 1,349 undated — exact. A2 ran without `kind`: headline right (1990s, 153 h, 254) but "2000s ~85 h", "undated 108 h", "2,275" are all-media numbers (audio included) and the answer did not say so. |
| ac-st-04 Thanksgiving hours + copies | FAIL OUT | **FAIL** | **FAIL** | A1: "109 distinct videos, 59.3 h, 31 extra copies" — correct for `text=Thanksgiving` with no `kind` filter, i.e. audio-only files counted as videos. Video-only is 97/117/20 extra, 41.2 h (all text) or 93/110/17, 40.8 h (filename/path/notes). A2: "105 distinct videos, 58.9 h, 28 extra" — same error on the filename/path/notes basis. Overstates Thanksgiving video by ~18 h. Both stated a basis, but a wrong one for the question asked, and called audio files "videos". |
| ac-st-05 bowser family (control) | PASS (19 named) | PASS | PASS | 16 primary / 19 incl. alternates, 1500–1933; Elaine → James William Bowser (1900–1962) → James William Bowser (1849–1913, Dorchester NB). Verified. |

### multi_hop

| id | H | A1 | A2 | notes |
|---|---|---|---|---|
| ac-mh-01 Donna's sisters before 1990 | FAIL OUT | PARTIAL | PARTIAL | Both: sisters from told note, no pre-1990 tags for either, evidence kind labelled ("as far as the tags show"). Both missed the spoken mention of Bonnie in AtHudsons-Thanksgiving-1984 (verified: `search_media text=Bonnie years=1900-1989` → 1 match, transcript snippet "there's Lisa's mother Bonnie"). Neither ran a text search for the sisters. Nothing wrong said. |
| ac-mh-02 Bonnie + Donna at Christmas | FAIL OUT | PASS | PASS | One file; Bonnie confirmed, Donna detected — labelled. Verified. |
| ac-mh-03 born in Ireland + video of children | FAIL OUT | PASS | PASS | Both scope to Rick's close ancestors (Mary Christina O'Connor, Christopher Dennis O'Connor, Ellen Ronan, Peter Ronan), say so, and give Eileen's 4 distinct videos (Christmas 1990, 1997 clip). Verified. Neither mentions Donna's Irish-born line (Doherty/Maxwell/Bell, 5 people, verified) — scope stated, so not wrong, but incomplete. |
| dp261009-001 Hudsons at Thanksgiving | FAIL OUT (probe: "not mentioned anywhere") | PARTIAL | PASS | A1 found only the tagged 94-min file because it AND-ed `tags=Hudson Family` with the text; missed AtHudsons-Thanksgiving-1984.mov (name says it). A2 found both, labelled the transcript as machine-made, and correctly excluded a 2009 clip where the narrator says "I almost said Hudson" (verified, catalog:513DDD4F). |

### conversation

| id | H | A1 | A2 | notes |
|---|---|---|---|---|
| ac-cv-01-t1 Richard Hudson | PASS | PASS | PASS | |
| ac-cv-01-t2 his kids | PARTIAL ("children: Donna Hudson." — tree only, note ignored) | PASS | PASS | Both agents: tree says Donna only; told note adds Bonnie/Paula/Glen, labelled as a note. |
| ac-cv-01-t3 oldest one's videos | FAIL OUT | PASS | PASS | Both say birth order is not recorded and ask Bonnie-or-Donna, offering Bonnie's one video. A1's "38 distinct confirmed Donna videos, e.g. Donna-MyGirl-1984" verified. A2 cites `q:q-417fdce2` from the ac-st-02 entry — a context leak across entries (runner contract says clean context per entry); number is right. |
| ac-cv-01-t4 when filmed | FAIL OUT | PASS | PASS | 2011 by Rick's date, "Christmas in January 2011". Verified yearSource=userDate. |
| ac-cv-02-t1 Dad's birth year | **FAIL WS** ("Dafydd ab Einion 'Y Giwn Llwyd' was born about 1360") | PASS | PASS | Both: tree already says 1929 (typed 'feberuary 22 1929'), People tab 21 Feb; "I can't change the tree". No edit claimed. |
| ac-cv-02-t2 his parents | FAIL (no parents for Dafydd) | PASS | PASS | George Breen 1898–1968, Muriel Lamb b. 1902. Chain fails for H on the wrong-subject turn. |

### loose_phrasing

| id | H | A1 | A2 | notes |
|---|---|---|---|---|
| ac-lp-01 materanl grandmother | PASS | PASS | PASS | Mary Christina O'Connor; both agents name the @I5@ duplicate as set aside. |
| ac-lp-02 the Hudsons at thanksgiving | FAIL (off-rails apology) | PARTIAL (1 of 2 files) | PASS (both) | Same miss as dp261009-001 for A1. |
| ac-lp-03 dad's side | FAIL (declined "Dad's side") | PASS | PASS | Both resolve dad → @I2@ and walk up to George/Muriel. UF (minor) in both: "Marine Corps in the 1940s" is cited to the People-tab note, which says "US Marine Corp" without a decade; the 1940s comes from brain items not called in this entry. True fact, wrong citation. |
| ac-lp-04 when was Ma born | PASS (31 Aug 1930) | PASS | PASS | Both add Chelsea and d. 3 Mar 2023 (verified). |
| lv261010-002 macgregor "ma greggor: | FAIL ("spell it out for me") | PASS | PASS | Both: subject MacGregor, honestly "I can't save anything", point to Gordon MacGregor @IB13@. |
| lv261010-010 pronounce magregor | **FAIL WS** (hint filed under "ma" = Rick's mother) | PASS | PASS | A2 gave the identical answer as -002; fine. |
| lv261010-015 tell me about the hudsons | PASS (13 Hudsons, 1380–1959 — headless got this right; live gave the whole tree) | PASS | PASS | Both give Donna's line and the 1984 Hudson Family video. |
| ac-lp-05 elain bowser (control) | PASS | PASS | PASS | Typo resolved by all three. |

### story

| id | H | A1 | A2 | notes |
|---|---|---|---|---|
| ac-sy-01 Dad's Marine Corps story | **FAIL WS** (Dafydd, 1360) | PASS | PASS | Both: "only the outline" — USMC 1940s, WWII veteran by the 31 Dec 1946 cutoff, never in combat; cited to the two brain items (verified). No invented bases, units or battles. |
| lv261010-012 tell about richard breen sr | PARTIAL ("born 21 February 1929." — right subject, no story, Marine missing) | PASS | PASS | A1 flags the 22-vs-21 Feb discrepancy. A2 relays "had 5 children" from Rick's People-tab note (cited) and Dick/Dad from brain:note.dad-breen-names (verified). No jargon leak in either. |
| ac-sy-02 Donna's family in 1959 | PARTIAL ("born 4 August 1959." — Brockton missing) | PASS | PASS | Both: 4 Aug 1959 Brockton, parents' ages 31/26 computed from tree years, "no family story specific to 1959", world context explicitly labelled general knowledge (A1) or omitted (A2). Neither listed the living grandparents the baseline expected; nothing invented. |
| ac-sy-03 tell me about donna (control) | PASS | PASS | PASS | A1's "1,070 catalog videos tagged with her name": tool says 1,070 catalog *records* (kind unspecified) — UF minor, same kind-overclaim class as st-04. Prime Computer QA / 17 years teaching verified in told item .3. |
| ac-sy-04 tell me about dan (control) | PASS (last sentence is kind-words, not a fact source) | PASS | PASS | b. 3 Feb 1982, oldest son, spouse Anna, 3 tagged videos incl. Mark_Bday_Thanksgiving_1984 and CapeCod_1994 — verified. |

## Where the agent lanes lost points (all of it)

1. **Media kind not pinned** (st-04 both, st-03 A2, sy-03 A1 wording). `catalog_stats` defaults
   `kind=any`; the agent said "videos" over totals that include ~3,100 audio-only records. This is
   the only class of wrong number in 66 agent turns.
2. **Tag-AND-text hides filename matches** (A1 dp261009-001, lp-02). `tags=Hudson Family
   text=Thanksgiving` cannot return AtHudsons-Thanksgiving-1984.mov because it carries no tag.
   A2 avoided it by running a plain text search first.
3. **Spoken mentions not searched** (mh-01 both). `people=Bonnie` finds tags only; the 1984
   transcript mention needed a separate `text=Bonnie years=1900-1989`. Neither agent ran it.
4. Minor citation hygiene: "1940s" cited to a note that doesn't say it (lp-03, both); one
   cross-entry `q:` id (A2 cv-01-t3).

A1 vs A2: redaction did not cost A1 any fact (filename matching still works redacted); A1's two
extra half-points lost came from search strategy, not from hidden text. A2's extra loss was the
unfiltered decade query.

## Tool-kit gaps the agents hit (these shape the real tool design)

1. `kind` should default to `video` for hours/count questions, or every `catalog_stats`/`search_media`
   total should carry `byStreamType` (it does today only for `group_by` queries). Root cause of
   every stats miss.
2. Date qualifiers are lost in `years`: "after 1930 before 1950" → `year: 1930` → "1877–1930" in
   three agent answers. Carry the display text and qualifier through `relatives`/`resolve_person`.
3. People search returns tags only. `search_media people=X` should also return (or the
   `resolve_person` notes should mention) transcript/caption mentions, labelled as mentions, so
   the agent doesn't have to know to run a second text query.
4. `tags=` AND `text=` is a trap when evidence lives in the filename. Either make `tags` an OR-able
   hint or make the result say "N more match the text but not the tag".
5. `catalog_stats born_in=` defaults to the whole 39k tree (156 medieval hits); a default scope of
   owner's and spouse's ancestors would have given Donna's Irish line for free.
6. `person_facts` returns CyberBrain item ids but not their text, so a second call is needed; one
   agent skipped it and mis-cited. Inline the short item text (or first sentence).
7. `relatives relation=all side=paternal` returned both parents (A2 noted "included both parents;
   not used") — `side` looks ignored for `all`.
8. No `tags=Thanksgiving` curated tag exists (0 hits); both agents fell back to text correctly, but
   a holiday tag or event vocabulary would make these counts tag-based and exact.
9. No write path for pronunciation hints — by design here; both agents said so honestly. The real
   Hallie needs one, keyed to the surname, never to a kin word.

## Data errors discovered

1. **Dad's birth day**: tree `feberuary 22 1929` (misspelled) vs People tab `1929-02-21`. People tab
   is the source of truth; the tree (FamilySearch G2S4-JF4) is off by a day and misspelled.
2. **Dad's death day**: tree `june 22 2008` vs People tab `2008-06-25`. Same source split, not in
   the suite; found while verifying @I2@.
3. **William Hudson @IB15@** death is "after 1930 before 1950" in the tree; the tool kit renders
   it as 1930 (tool bug, item 2 above), so every lane that cited it printed a wrong death year.
4. **Catalog date inference**: `2025-08-22_Donna-and-Libby-on-Porch-2025-08-22_MA5A3201.mov`
   (FamilyArchive/30_Video/2020-2029/2025/) carries `year: 1984, yearSource: inferredDateRange`.
   The inferred range beat a filename and a path that both say 2025. It is inside the 1980s Donna
   count (44), so the expected number in the suite inherits the defect. Worth a sensor.
5. **Eileen @I3@ has three parents in the tree** — the duplicate `Mary O'Connor` @I5@ (b. 1905)
   is still linked; the identity decision hides it in `resolve_person` but `person_facts` lists it.
6. Richard Sr's People-tab note says "married in 1956, then had 5 children"; the kinship rows
   carry four children and Eileen's note (per baseline) says 1955. Rick knows the why; noting the
   split only because an agent will read the note verbatim.
7. Baseline check: no expected answer was found wrong against the data. The suite's st-03/st-04
   regexes assume a video basis, which is right, but the tool default does not enforce it.

## Three side-by-side examples for Rick

**1. "how many people in the family tree have the surname Hudson?"**
- Hallie (live and headless): "Hudson is an English patronymic surname: it comes from the Middle
  English personal name Hudde plus 'son.' ..." — a confident answer to a different question.
- Agent (A1): "11 people have Hudson as their primary name in the tree, born between 1380 and
  1959; counting alternate names it's 13 [q:q-b396cee3]."
- Trace: `catalog_stats surname=Hudson` → count 11, countIncludingAlternateNames 13,
  birthYearSpan [1380, 1959]. One call.

**2. "I think Dad's birth year is wrong in the tree — he was born in 1929" → "ok what does the tree say about his parents?"**
- Hallie: "Dafydd ab Einion 'Y Giwn Llwyd' was born about 1360." → "The family tree doesn't
  record any parents for Dafydd ab Einion."
- Agent (A2): "The tree already has 1929 for Richard Harding Breen Sr [gedcom:@I2@]. Only the day
  differs: the tree says 22 February 1929 while your People-tab profile says 21 February. I can't
  change any records." → "George Breen (1898–1968) [gedcom:@I8@] and Muriel Lamb (b. 1902)
  [gedcom:@I4@]."
- Trace: `resolve_person Dad` → @I2@ (kin word relative to owner); `person_facts @I2@` → birth
  'feberuary 22 1929' Boston, People tab 1929-02-21, parents @I8@/@I4@. Second turn needed no
  new call.

**3. "show me videos of the Hudsons at Thanksgiving"**
- Hallie (probe, 11 of 11 runs): "I don't see 'thanksgiving' mentioned anywhere, but I have 2
  videos of Hudson Family — want those?"
- Agent (A2): "Two good matches: 1984-xx-xx_Thanksgiving-1984_Improved_slp.mov, tagged Hudson
  Family (confirmed), 94 min; and AtHudsons-Thanksgiving-1984.mov, 1984, whose transcript mentions
  Glenn Hudson (one extra copy). A 2009 Thanksgiving clip only mentions 'Hudson' in speech, so I
  wouldn't count it. Transcripts are machine-made."
- Trace: `search_media text="Hudson Thanksgiving" in=filename,...,transcript` → 2 distinct /
  3 records (AtHudsons 1984 + a 2009 .MTS whose narrator says "I almost said Hudson");
  `search_media tags="Hudson Family" text=Thanksgiving` → the 94-min archived file;
  `search_media people=Hudson text=Thanksgiving` → 0 (no person named Hudson is tagged).

Honourable mention: "find nana" — Hallie live invented "111 people named Nana"; both agents asked
"Muriel Lamb or Mary Christina O'Connor?" after one `resolve_person` call that also excluded the
duplicate record.

## Files

- Lane H run: `~/Library/Logs/VideoScan/hallie-eval/acceptance-v1-20261010.jsonl` (+ `.graded.jsonl`, `.summary.json`)
- Lane A1: `<scratchpad>/hallie_demo/agent_answers.json`; Lane A2: `.../agent_answers_unredacted.json`
- Tool kit: `scripts/hallie_demo/tools.py`, snapshot in `<scratchpad>/hallie_demo/snapshots/`
