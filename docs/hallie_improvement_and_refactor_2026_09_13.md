# Hallie improvement and bounded refactoring — September 13, 2026

Rick requested better Hallie conversation, refactoring based on the overnight
assessment, and joint review with Claude. This plan separates user-visible
improvements from behavior-preserving extractions. Source baseline: `3e663856`.

## What would make Hallie better

Prioritize reliable continuation of a conversation and answers that address the
question. The saved replay supplies concrete failures; it does not establish
that a different model or a larger prompt would fix them.

| Priority | Observed conversation | Desired behavior and acceptance check |
| --- | --- | --- |
| 1 | “How many videos do you have?” → “How many of those are from the 90s?” → “and how many from the 80s” (`cc002`, `cc003`) | Carry the catalog-count operation and its scope through both follow-ups; return independently computed decade counts. Changing the decade replaces the previous decade filter. Test the full sequence, including cancellation and an intervening unrelated question. |
| 2 | Biography of Rick → “show me” (`lv260911-003`) | Carry the resolved person and the available action. Execute an unambiguous offered action, or ask a short clarification when several targets are plausible. Test cards, tree/gallery navigation, and stale actions against captured identity. |
| 3 | Highest royalty/title query → generic statistics (`lv260907-002`); “title like king” → person lookup (`lv260907-004`) | Recognize title search as a tree attribute query. State the scope and evidence; distinguish titles from names. If ranking unlike titles has no defined policy, clarify rather than invent a total ordering. |
| 4 | “play the longest video in the archive” → unresolved anchor “archive” (`cs030`) | Interpret archive as catalog scope, resolve the longest eligible record, and pass its stable ID to the existing action path. Cover unavailable media and deterministic ties. |
| 5 | Challenge about requesting Thankful Pratt’s photograph → only her birth date (`lv260902-003`) | Recognize a challenge to the previous suggestion, explain its basis and correct it when inappropriate. Do not turn a rhetorical challenge into a birth-date lookup. Do not assume her dates prove photography was impossible. |

These are proposed behavior changes, each requiring its own focused fix and
regression. The three strict replay failures already prompted Claude's routing
commit `81ac3f7e`; its review must be distinguished from a new real-model run.

## Improve the measurement with the conversation

The September 13 visible run completed **418/418** nightly questions: strict
**28/31 passed**, advisory **60/387 flagged**. Actions were disabled. The model
was `qwen3.8:27b-mlx`; binary source revision was not independently established.
Those results precede the latest routing fix. Advisory unflagged is not a
correctness grade: the irrelevant royalty statistics and the failed 80s follow-up
both escaped flags.

Promote the examples above into reviewed multi-turn expectations. Check the
requested operation, resolved identity, relevant facts and intended action—not
only the route or absence of forbidden words. Keep human judgments distinct from
automatic structural checks. Score unanswered, wrong, irrelevant, and stale-action
responses separately using existing artifact formats; any format change is a
separate decision. Include paraphrases and neighboring intents so route patches
do not merely recognize the exact saved sentence.

Use the current model and captured data for the next comparison. Measure response
time and timeout/fallback rates alongside correctness. Test the real action path
with injected sinks first: `--no-actions` replay cannot establish playback or UI
correctness. A live app/model rerun needs an appropriate machine window.

## First two refactors

1. **People identity and guarded profile operations.** Finish review and correction
   of the UUID migration consumers first. Separate profile value/codec from
   persistence, then centralize identity resolution for save/delete. Preserve
   missing, ambiguous and quarantined states through repeated operations; a
   present-but-missing UUID must never become name-based authorization. Test
   actual writes with two namesakes, stale selection and quarantined profiles.
   Preserve migration, file formats and the People tab's authority for biography.
2. **Hallie response/action commit boundary.** Extract one owner for accepting a
   completed turn and dispatching its existing transcript/card/speech/action
   effects. Carry captured turn/session identity and preserve current actor
   ownership. Pin cancellation, replacement, duplicate completion and stale
   action behavior before moving code. Separate any newly discovered behavioral
   fix from the extraction. Avoid concurrent routing/model/prompt redesign.

Use the same resolved identity and captured data revisions through clarification
and execution as the next incremental step where missing. Do not add a second
session authority beside an existing owner just to shorten a view file.

## Review and validation

Claude confirmed ownership in team-channel #1469: Codex owns the isolated Hallie
response extraction; Claude owns People correctness fixes, the spouse-route
correction, Promote completion and Hallie catalog/tree mode selection. People
extraction is deferred until its correctness fixes land. Codex's durable findings
are in [the post-merge review](codex_postmerge_review_2026_09_13.md).

Rick explicitly requested that refactoring stay on a branch so he and Claude can
continue rapid development on Promote. Worktree:
`codex-worktrees/hallie-refactor-20260913`, branch
`refactor/hallie-boundaries-20260913`. Leave it unmerged. Avoid shared build output
and application/test-host launches while Rick works. Claude reviews the finished
patch; an unanswered review request is not approval.

Headless harness verification on this baseline: `python3 -B -m unittest discover
-s tests -p 'test_hallie_*.py'`: **52 passed**, 0.322 seconds. This is a harness
unit result, not a real-model replay or Swift application test.

For each extraction, run relevant existing suites plus behavioral boundary tests.
Use poisoned state for identity/global-state paths. Add a 100k-record budget only
where the change traverses records; use Release for performance measurements.
The media matrix is applicable if media-opening logic changes, not to a pure
ownership extraction with injected sinks. No app/UI/test-host launch on Rick's
active M4. Do not change storage schemas, logging contracts, threading models,
or recovered media as part of this work.

Evidence: [overnight assessment](refactoring_assessment_2026_09_13.md),
[restart handoff](codex_restart_handoff_2026_09_13.md), and saved paired replay
artifacts under `~/Library/Logs/VideoScan/hallie-eval/visible-20260913-1020/`.
