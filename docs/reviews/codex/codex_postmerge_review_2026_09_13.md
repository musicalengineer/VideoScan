# September 13 post-merge correctness review

Reviewed baseline `3e663856`, including Hallie `81ac3f7e` and People
`9a8fb4c4` merged as `3e915900`. Independent source review; app tests and
real-model replay were not run. Line references describe that baseline.

## People: HOLD

1. **Repeated stale-selection operation can write a namesake.**
   `PersonFinderModel.swift:641–644` clears `activeProfileUUID` on missing-profile
   refusal but retains `personName` and settings/rejections. A second operation
   enters the unique-name fallback at `:609–619`, then quick-save (`:663–675`)
   or rejection sync (`:568–570`) can write the surviving same-name person.
   Preserve unresolved identity until explicit reselection. Add a two-operation
   regression without resetting the missing UUID between calls; the existing
   sensor resets it and therefore misses this transition.
2. **Catalog tag writeback can bypass namesake protection.**
   `PersonFinderModel+JobLifecycle.swift:447` checks ambiguity at scan start.
   Adding a namesake during a scan does not guard completion at `:1364` →
   `ContentView.swift:174–180` → `VideoScanModel+FamilyTagging.swift:47–111`.
   Cache restoration calls the same name-only callback at lifecycle `:434`
   without the start guard. Validate identity at the actual catalog write sink;
   test mid-scan identity changes and cached restore, asserting unchanged tags.
3. **Photo-link replacement is not crash-safe.**
   `POIStorage.swift:980` removes the old symlink before creating its replacement.
   Interruption between operations leaves no link for a resumed enumeration;
   creation errors are swallowed and callers mark `linksRebased` at `:682`,
   `:690`, `:842`. Rollback likewise loses retry information after rebase failure.
   Prepare a sibling replacement and atomically replace the link; propagate
   failure and retain pending migration/rollback work. Test failed replacement,
   restart and dereferencing, not only successful target-string rewriting.

The final delta correctly added guards for quarantined deletion, conflicting
import UUIDs, ambiguous legacy kinship upgrades, and the validation/holdout write
sinks. Those improvements do not close the three paths above. Migration backup
material exists; the finding concerns automatic preservation and retry behavior.

## Hallie routing: HOLD on a narrow neighboring intent

`HallieLineageQuestion.swift:954–975` accepts “who did **his father** marry”
and “who was **her mother** married to” as literal `His Father`/`Her Mother`
subjects. The new stop set rejects my/our/their but admits these nested relatives.
`HallieTurnExecutor+Conversation.swift:726–734` resolves only whole-string
pronouns, then emits a spouse query for that literal person. Relative-fact
execution cannot rescue it: `HallieTurnExecutor+RelativeFacts.swift:11–12`
excludes `.kinship`.

Refuse unsupported nested subjects in this recognizer, or resolve them through
the existing contextual path. Add neighboring-route regressions before approving
the broad route change. The separate “my grandmother” → name “Marry” issue
predates this commit. The three original strict failures appear corrected by
source inspection; that is not a fresh model-run result.

Corpus changes reviewed separately: no existing assertion was weakened.
`followsPrevious` repairs the relevant conversation links, and biography is the
correct category for Edward III. However, `hallie_eval.py:560` handles biography,
kinship and catalog labels identically for its decline check. Relabeling alone
does not verify semantic routing or answer relevance.

## Coordination

Findings delivered to Claude in team-channel #1467 and #1468. A review request
or an unanswered mailbox message is not approval. The Hallie local commit helper
is being extracted separately in `refactor/hallie-boundaries-20260913`; the
findings above are correctness work, not silently folded into that refactor.

## Date cleanup: HOLD on remaining provenance closure

Final delta `4a267e31` fixes unique recovery-sidecar naming and uses
`.withoutOverwriting` (`VideoScanModel+DateInference.swift:675–683`). Failures
during directory creation, encoding or writing return before clearing fields
(`:624–636`). The inspected tests cover cycles, missing links and two sidecars
within one second; no injected actual unwind write failure was found.

A remaining sequence is A (hash `aaaa`, own date) → B (hash `bbbb`, inherited
from A) → C (hash `aaaa`, inherited from B). The first cleanup clears B but keeps
C because C matches the earned origin A (`:600–601`). Clearing B's provenance
(`:633–636`) then destroys C's path to that origin. On the next cleanup, C resolves
to undated B and is cleared (`:652–662`). The new descendant-chain test uses the
conflicting hash for every bad descendant and misses this return-to-origin-hash
case.

Either include affected descendants in the first backed-up unwind or explicitly
rebase a retained, verified descendant to its earned origin, preserving recovery
for changed provenance. Pin repeated cleanup/idempotence and the recovery contents.
This is source-level evidence, not an executed production repro or live-data
repair. The separate dossier partial-MD5 evidence-copying concern remains outside
this final delta.
