# Codex overnight review — September 7–8, 2026

Rick directly authorized coordinated Hallie improvements, deferred debt,
refactoring and test review. Codex owns independent review; Claude owns active
production corrections. No push. Codex tasks are `machine: none` (headless).
This is a live checkpoint, not a completed overnight or full-main sign-off.

## Working agreement

Team #1179 amends automatic HOLD→revert: correct narrowly when safe; revert
when that is the safer recovery. Use focused red/green tests while iterating
and broad integration checkpoints before declaring GO. Neither many passing
tests nor a local model's confidence substitutes for correct acceptance cases.
Two previously reported full-suite timing failures remain unresolved until
isolated measurement; “green except failures” is not a green suite.

## Current review findings

| Changes | Verdict | Concrete issue |
| --- | --- | --- |
| `ea588b97` | HOLD | Relation language used as a subject becomes the operation: “when was his father born?” can ask for the father's father. Mixed “where did he die after being born in France?” overrides deathPlace to birthPlace. |
| `3fe804a0` | GO for its two corrections only | Inherited `31cd14df` follow-up issue remains: “where were his mother and father born?” bypasses exactly-one-relation exclusion, reusing prior person's birthplace. |
| `78396d76` | HOLD wiring unchanged | “alive,” maternal ancestry, “born in 1800,” and “Europe or Asia” can lose constraints. New England maps to United States; England text fallback includes New England. |
| `5398c6fa` | Coverage correction needed | Unknown birth dates disappear before `considered/unrecorded` counting for time-filtered queries. Nonempty unclassifiable birthplaces also lack uncertainty accounting in count. |
| `9217b12f` | Algorithm GO, ancestry-policy correction needed | BFS shortest/depth/cycle behavior is sound. `allRecordedParents` includes alternative families, but prose does not qualify that path. Reversed subject bridge attribution also needs a minor correction. |

Evidence: source-level independent QA. Sent #1180–#1181. These are specific
wrong-answer paths, not a request to handle every possible natural-language
utterance. Preserve useful simple guards; abstain when constraints are not
accounted for. Tests currently bless some widened geography semantics, so
unchanged full-suite success would not establish correctness.

Independent execution: existing `TreeStatisticsTests` **14/14 passed**, including
the 100k sensor (~4.06s), before Claude's corrective edits. New Codex commit
`3bfd62db` adds **2 passing tests** covering a real cycle, an exact shortest
chain with the longer branch listed first, inclusive depth and reverse absence.
An independent QA pass approved those fixtures. The tests use one parent
family per person and do not endorse alternative-family ancestry semantics.

Claude is actively correcting statistics production source; no corrective
SHA or final verification has yet been delivered. Codex left those edits alone.

## Risk-ranked debt, not a line-count ranking

1. **Intent and identity boundary:** `HallieTurnExecutor` plus Conversation,
   SpeakerKinship, `ArchivistGraphExecutor` and `ArchivistFollowUpResolver`.
   Recent repeated wrong-person/wrong-field failures show real coupling.
   Separate mention discovery from final identity, and request recognition
   from operation override; carry explicit resolved/ambiguous/absent/abstain
   outcomes. Changing this contract is a design step, not a cosmetic split.
2. **`HallieLineageQuestion`:** parsing, identity/scope, traversal dispatch and
   prose/cards coexist. Extract pure recognition and result construction only
   behind real-route characterization tests. Preserve detection precedence.
3. **`FamilyTreeLiveModel`:** asynchronous loading and coordinated publication
   of graph, identity directory, selected person, caches, notes and scene.
   `installSteps` has deliberate ordering. Splitting it without publication
   and stale-load tests risks mixed-generation UI state. Highest-risk tests:
   graph replacement reusing local IDs, selection preservation and delayed
   older task completion.
4. **`ArchivistChatWindow`:** request lifetime, clarification chips, transcript
   writes and scene navigation. Pure chip/presentation builders are candidates;
   changing task ownership/cancellation or SwiftUI state lifetime is not a
   headless-only safe extraction.
5. **Large views:** `FamilyTreeDemoView` is not harmless just because it is a
   view: it owns sheets, selection, research and pronunciation edit state.
   Extract stateless rendering first, keep state ownership stable. Do not
   reorder modifiers or replace identity to improve a length metric.

Other large catalog/confirmation modules merit later assessment, but their
length alone does not outrank the observed Hallie failures. Avoid unrelated
catalog cleanup during the current answer-quality work.

## Refactor validation boundaries

- Pure Foundation helpers/Core algorithms: headless tests can validate logic,
  malformed inputs, poisoned state and 100k+ scale where appropriate.
- App-route helpers: compile the app target and drive real detector→executor→
  response/card fixtures. Helper-only tests cannot prove production wiring.
- SwiftUI ownership/layout/lifecycle: require a routed app/UI checkpoint on M5
  or a Rick-authorized quiet M4; no claim of UI equivalence from unit tests.
- Preserve `private`/`fileprivate` encapsulation deliberately, rather than
  widening everything to internal merely to move code between files.
- Match each before/after measurement and test result to a specific SHA.

## Model review calibration

`eb527691` source GO covered independent nightly model/host selection, not
Qwen model quality. Claude reports earlier useful nightly findings came from
a different model. Treat local-model findings as unverified suggestions;
evaluate precision and seeded-bug detection using the same source/context
budget, not speed or number of findings alone. No configuration changes here.
