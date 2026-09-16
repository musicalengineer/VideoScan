# Hallie response application extraction

## Status update — September 15, 2026

The extraction commit `2dbc6c6f` is now an ancestor of main `e3a093eb`, merged
via `8f209fa2`. The existing local app-host Debug nightly log
`~/Library/Logs/VideoScan/nightly_test_20260915_020003.log` at `34aeda64`
records all 12 response-commit tests passing (lines 13467–13492), including
`committedMemoryIsVisibleBeforeMessageActionAndTheNextClause`.
Thus the unmerged and integration-pending statements below describe the original
handoff, not current status. The overall nightly had other failures; this is
focused integration evidence, not a green full-suite result or a fresh Xcode 27 run.

## Original handoff

Branch: `refactor/hallie-boundaries-20260913`, based on `3e663856`.
Worktree: `codex-worktrees/hallie-refactor-20260913`.
Rick requested branch isolation while he and Claude finish Promote in rapid
development mode. This patch remains unmerged.

## Change

The chat window previously applied a completed local Hallie response directly:
speech, conversation state, evidence, transcript, chips and immediate actions.
`HallieResponseCommit.apply` now owns that synchronous sequence, with injected
callbacks for external effects. The window supplies its existing state and
callbacks. The private `commitHallie` wrapper now takes a request UUID, and both
local callers pass their captured request UUID.

The helper is stateless and `@MainActor`; the window retains task/session
authority. Cancellation and request replacement are checked before any callback.
The existing guards at both callers remain. A current request may commit several
split clauses, as before; there is no duplicate-completion cache.

The extraction preserves pending clarification on repair replies, prior evidence
for follow-up media actions, memory updates before the next clause, picker voice
overrides, chip order, transcript fields and explicit media-action precedence.
State publication occurs synchronously before transcript and action callbacks.
Remote response handling, mode selection, routing, model/prompt policy and
storage are outside the diff.

## Scope and review

- `ArchivistChatWindow.swift`: 2,720 → 2,637 lines; `commitHallie`: 125 → 50.
- New helper: 171 lines. Total production size increases by 88 lines; the value
  is an executable response boundary, not a reduction in total lines. Two
  orphaned label wrappers were removed during review.
- Xcode synchronized folders include the helper automatically; no project-file
  or dependency changes.
- Independent Codex QA: **APPROVE, source review**, no blocking findings.
- Claude reviewed the production move as faithful in #1477/#1478, with HOLD
  findings on the test-side actor annotation, a stale citation source sensor,
  and orphaned label wrappers. The actor annotation was already fixed in the
  final test snapshot. The citation sensor now reads the helper, the wrappers
  are removed, and negative checks still cover the window wrapper. Final
  post-fix integration verification remains pending.

## Validation

Production syntax parsing and `git diff --check` pass. Source review checked
types against existing declarations, value/copy-on-write state behavior,
effect ordering, typed chip mappings and both caller guards.

Added 12 permanent Swift Testing cases in `HallieResponseCommitTests.swift`.
**11/11 passed** in a temporary headless Debug harness using the unchanged
production helper, extracted payload declarations, and doubles for app
boundaries. Final restored test time: 0.002 seconds; an incremental harness build
took 1.87 seconds.
These check rejected-request effects, speech, clarification, sessions, evidence,
transcript fields, typed chips, media/navigation precedence, and multiple clauses.

The twelfth test checks real conversation-memory publication before subsequent
effects/clauses. It was explicitly omitted from the temporary harness because
its conversation memory is inert; it remains **unexecuted** pending application
integration. Passing the other 11 does not validate that dependency or full
application type compatibility. The existing source-wiring test now follows the
wrapper into the helper rather than requiring moved code to stay in the window.

A deliberate guard removal in the temporary helper made the zero-effects test
fail with 15 issues. The exact production helper was restored (`cmp` checked)
and all 11 cases passed again. Both permanent test files pass syntax parsing;
7 focused forwarding/typed-choice source assertions pass. Harness reproduction
and logs remain in the ignored worktree directory
`.build/hallie-commit-headless/` (`prepare.py`, `run.log`, `mutation.log`,
`restored.log`). These temporary doubles are not shipped with the app.

After Claude's review fixes, Debug revalidation passed all 11 behavioral cases
(0.001 seconds). A second headless run also executed the exact latest bodies of
the clarification and bounded-evidence source sensors: **13/13 passed**, zero
failures, 0.010 seconds. Logs: `claude-review-rerun.log` and
`claude-review-with-sensors.log` in the same harness directory. This does not
replace the pending real-memory/app integration run.

Full application type integration and the existing Swift suites have not been
run. No VideoScan app, app test host, UI, real model or media action was launched
during this work; Rick's active M4 and shared build output were left available
for Promote.

Scale/media matrix: this extraction adds no traversal over catalog records and
does not change media opening. Existing citation lookup is retained. Poisoned
speech settings and stale/cancelled request identity are tested through injected
callbacks rather than real global state.

## Integration handoff

Review the helper and local wrapper together. Claude's concurrent Hallie mode
selection work may touch the same window, so integrate only these local response
hunks after his review. Run focused app suites on an available test machine or
an explicitly scheduled M4 window before integrating. Keep any newly discovered
behavioral correction separate from this extraction.
