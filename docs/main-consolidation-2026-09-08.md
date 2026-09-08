# Main consolidation — September 8, 2026

Rick asked for docs and code to be available on main. At inspection, main was
`e5481f9b`, including the overnight changes and couple-portrait merge, and
matched the locally known origin/main. No tracked modifications existed in
the main checkout.

Added the three previously untracked documents to main:

- [Historical Codex handoff](codex-handoff-2026-09-06.md)
- [Model-management design proposal](hallie-model-management-policy.md)
- [August 21 hardware inventory](mac-hw-inventory-2026-08-21.md)

Current work is described in the [morning brief](morning_brief_2026-09-08.md)
and [Codex overnight review](codex-overnight-review-2026-09-08.md).

## Older work preserved, not blindly merged

Several branches not ancestors of main contain patch-equivalent commits
already integrated: navigation chips, fixity cycle4/path escape, evidence
coverage, follow-up confirmation, lineage pronouns and maternal extraction.

Other divergent branches contain older unvalidated/parked changes, including
ffmpeg route parity, GEDCOM primary-parent experiments, explicit-year recovery,
self-reference, age and capability fallback work. The old vital-date branch
includes a tree-wins policy contrary to Rick's current People-tab authority.
The metrics branch is a separate metrics publication history, not app code.
These require disposition by change, not a blanket merge of branch tips.

Uncommitted historical work also remains in three worktrees:

- `.claude/worktrees/agent-a090fb57ec2b93513`: presence executor and tests.
- `.claude/worktrees/agent-a21fc6ac89bdbaebb`: AST/kinship and decoding tests.
- `codex-worktrees/hallie-presence-question-gate`: AST/kinship/translator and tests.

Claude was asked to identify whether any of these are current rather than
superseded. All were left intact. This consolidation is **not** a claim that
every historical experimental branch has been merged or reviewed.

Generated `default.profraw` and the nested worktree directory were not added.
No push was performed by Codex.
