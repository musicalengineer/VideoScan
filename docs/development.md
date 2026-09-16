# Development and review

**Updated:** 2026-09-16. A guide to durable engineering lessons and current
references; historical findings below are review questions, not a claim that
those bugs remain in today's code.

## Start here

- [Software development policy](software_dev_policy.md): contribution, review,
  merge and regression-test rules.
- [Testing](testing.md): test categories, isolation and machine routing.
- [Compute assignments](compute-assignments.md): fleet responsibilities.
- [Architecture](architecture-overview.md): subsystem boundaries.
- [Team channel](team-channel/README.md): local coordination.
- [Engineering Room](../tools/engineering-room/README.md): current discussion
  service and its controls. The July invitation and prototype review are
  superseded by that maintained operational guide.

Rick remains the decision authority. Peer discussion is attributed context,
not authorization. Keep discussion access separate from a coding session's
workspace permissions. Bound automated work explicitly, preserve attribution,
make failures visible, and keep credentials out of transcripts.

## Durable review questions

The June assessment and refactor suggestions repeatedly identified boundary
risks. Recheck these against the implementation being reviewed:

- **Paths and identity:** use path-component containment, not raw string
  prefixes (`Drive` must not include `Drive Backup`). Rename and move operations
  should preserve stable record/person identity and recover cleanly on failure.
- **Persistence:** atomic replacement prevents partial files but does not
  coordinate competing writers. Check revision conflicts or ownership, and
  ensure refusal to read a newer schema also prevents later overwriting it.
  Test interrupted migrations and failed saves before source cleanup.
- **Derived state:** search indexes, cached facts and UI projections must
  invalidate on ordinary edits as well as full rescans. Exercise the entire
  mutation-to-query sequence.
- **Cancellation:** a structured task timeout cannot bound a child that is
  stuck in blocking I/O. Check actual subprocess termination/reaping and
  cancellation behavior, including a child that stops producing output.
- **Responsiveness:** keep probing and catalog-wide work off the main actor
  and out of view bodies. Use scale budgets and shared process supervision;
  decomposition alone does not fix blocking work.
- **Concurrency:** audit mutable reference types crossing actor boundaries and
  `nonisolated(unsafe)` state. Narrow published state to reduce unnecessary UI
  recomputation, while preserving one coherent source of truth.

Current findings and evidence belong in dated review reports, including
[September 15 code review](codex_review_2026_09_15.md) and
[technical-debt review](tech_debt_review_2026_09_15.md). Their test counts and
verdicts apply to the revisions named there. They are not a current build badge.

## Historical branches and administrative notes

The August 31 branch purge and September 8 main-consolidation reports recorded
completed housekeeping. They did **not** certify every experimental branch:
ffmpeg route-parity and other experiments were parked or unvalidated at that
point. Assess each remaining branch by its diff, tests and current relevance;
do not blanket-merge old tips. The `metrics` branch has a separate publication
history and is not an app-code integration branch.

The June catalog-clutter inventory was a proposal, not an approved requirement:
reduce toolbar density, group advanced actions, and consider background
post-scan analysis only when cost and user control are addressed. Check today's
UI and Rick's current direction before implementing those old suggestions.

## Source history

Consolidated during the September 16 cleanup from `codex-assessment-jun29.md`,
`refactor_suggestions.md`, `purged_branches_2026_08_31.md`,
`main-consolidation-2026-09-08.md`, `engineering-room-invitation.md`,
`engineering-room-claude-findings.md`, and
`catalog_view_clutter_inventory_2026_06_06.md`. Original texts and their dates
are recoverable using the [documentation map](documentation-map.md).
