# Hallie take-two scoring sheet

Suite: `tests/hallie_acceptance_v1.json` (frozen 2026-10-10, sha256
`ebd68308c852166227f2389f8987d1a5260f4eab9095e93573990bc047b1d2fc`), 29 entries / 33 turns.
Expected answers, numbers and Hallie's live answers: `hallie_baseline.json` (never shown
to the blind agent). Score each category separately; a category passes only at its bar.

## Pass bars

| category | bar | what fails a row |
|---|---|---|
| no_bluff | 100% | any wrong subject; any uncited fact; a guess where "not recorded" or "which one?" was right |
| stats | 100% exact | any number that differs from `expectedNumbers` for the basis the answer states; no basis stated |
| multi_hop | ≥ 80% | wrong person/file; a transcript mention presented as a confirmed appearance |
| conversation | ≥ 80% of turns | lost referent; a wrong-subject turn fails the whole chain; claims of edits |
| loose_phrasing | ≥ 90% | typo / kin word / odd quoting not read as the clean form |
| story | every row | anything uncited or invented; world context not labelled |

Success for the demo: no_bluff and stats flawless; most of multi_hop and conversation right.

## Per-row sheet

Mark each cell ✓ (pass), ✗ (fail) or – (not in this category). `cited` = every fact
carries an id the agent actually got. `subject` = right person/file (subjectIDs).

| id | no_bluff | stats | multi_hop | conversation | loose_phrasing | story | cited | subject | Hallie live | note |
|---|---|---|---|---|---|---|---|---|---|---|
| ac-nb-01 tell me about Bonnie | | – | – | – | – | – | | | MISS | |
| ac-nb-02 find nana | | – | – | – | – | – | | | WRONG-CONF | |
| ac-nb-03 Donna's great-grandfather, Hudson side | | – | – | – | – | – | | | not asked | |
| ac-nb-04 find videos of bonnie (control) | | – | – | – | – | – | | | GOOD | |
| ac-st-01 surname Hudson count | – | | – | – | – | – | | | WRONG-CONF | |
| lv261010-014 count surname hudson | – | | – | – | – | – | | | WRONG-CONF | |
| ac-st-02 Donna videos 1980s | – | | – | – | – | – | | | not asked | |
| ac-st-03 decade with most video | – | | – | – | – | – | | | not asked | |
| ac-st-04 Thanksgiving hours + copies | – | | – | – | – | – | | | not asked | |
| ac-st-05 bowser family (control) | – | | – | – | – | – | | | GOOD | |
| ac-mh-01 Donna's sisters before 1990 | – | – | | – | – | – | | | not asked | |
| ac-mh-02 Bonnie + Donna at Christmas | – | – | | – | – | – | | | not asked | |
| ac-mh-03 born in Ireland + children on video | – | – | | – | – | – | | | not asked | |
| dp261009-001 Hudsons at Thanksgiving | – | – | | – | – | – | | | WRONG-CONF (probe) | |
| ac-cv-01-t1 Richard Hudson | – | – | – | | – | – | | | GOOD (similar) | |
| ac-cv-01-t2 his kids | – | – | – | | – | – | | | not asked | |
| ac-cv-01-t3 oldest one's videos | – | – | – | | – | – | | | not asked | |
| ac-cv-01-t4 when filmed | – | – | – | | – | – | | | not asked | |
| ac-cv-02-t1 Dad's birth year | – | – | – | | – | – | | | not asked | |
| ac-cv-02-t2 his parents | – | – | – | | – | – | | | not asked | |
| ac-lp-01 materanl grandmother | – | – | – | – | | – | | | not asked | |
| ac-lp-02 the Hudsons at thanksgiving | – | – | – | – | | – | | | OFF-RAILS (probe) | |
| ac-lp-03 dad's side | – | – | – | – | | – | | | not asked | |
| ac-lp-04 when was Ma born | – | – | – | – | | – | | | not asked | |
| lv261010-002 macgregor "ma greggor: | – | – | – | – | | – | | | MISS | |
| lv261010-010 pronounce magregor as "ma gregor" | – | – | – | – | | – | | | WRONG-CONF | |
| lv261010-015 tell me about the hudsons | – | – | – | – | | – | | | WRONG-CONF | |
| ac-lp-05 who was elain bowser (control) | – | – | – | – | | – | | | GOOD | |
| ac-sy-01 Dad's Marine Corps story | – | – | – | – | – | | | | not asked | |
| lv261010-012 tell about richard breen sr | – | – | – | – | – | | | | GOOD + leak | |
| ac-sy-02 Donna's family in 1959 | – | – | – | – | – | | | | not asked | |
| ac-sy-03 tell me about donna (control) | – | – | – | – | – | | | | GOOD | |
| ac-sy-04 tell me about dan (control) | – | – | – | – | – | | | | GOOD | |

## Category totals

| | no_bluff | stats | multi_hop | conversation | loose_phrasing | story |
|---|---|---|---|---|---|---|
| rows | 4 | 6 | 4 | 6 turns | 8 | 5 |
| blind agent pass | | | | | | |
| Hallie live pass (asked rows only) | | | | | | |
| bar | 100% | 100% | ≥ 80% | ≥ 80% | ≥ 90% | all |
| met? | | | | | | |

## Running today's Hallie on the same suite

The headless shell needs a built VideoScan binary (newest found, or `--bin`) and the
local composer model; the app does not need to be running. Rick or the Manager runs:

```
/Users/rickb/dev/VideoScan/venv/bin/python /Users/rickb/dev/VideoScan/scripts/hallie_eval.py run --corpus /Users/rickb/dev/VideoScan/tests/hallie_acceptance_v1.json --out /Users/rickb/Library/Logs/VideoScan/hallie-eval/acceptance-v1-20261010.jsonl
/Users/rickb/dev/VideoScan/venv/bin/python /Users/rickb/dev/VideoScan/scripts/hallie_eval.py grade --run /Users/rickb/Library/Logs/VideoScan/hallie-eval/acceptance-v1-20261010.jsonl --show 40
```

`grade` checks the lexical assertions (`mustMatch`, `mustNotContain`, `mustContain`,
`expect`). `expectedNumbers` and `subjectIDs` are for the human pass with this sheet.
