# VideoScan — Software Development Policy

**The onboarding doc.** If you are a new agent or developer contributing to
VideoScan, this is the process. It is deliberately short; follow it exactly.
(Replaces `development_practices.md` and `features_and_branches.md`, 2026-07-25.
Their full content lives in git history if you need the deep dives.)

## The One Rule

**Nothing merges to main unless BOTH are true:**

1. **It has been code-reviewed** by Claude or Codex (latest cloud model).
2. **Rick has approved it** — normally by building and spot-testing the branch.

Exception: documentation-only commits (`docs/`, team-channel messages) and
metrics/CI publishes may go straight to main under standing permission.
Everything that touches code takes the gate.

## Roles

| Who | Role |
|---|---|
| Rick | Director / CTO. Final approval on every merge. Architect of record. |
| Claude | Principal developer. Manages sub-agents (feature-dev, bug-fix, testing, qa, …). |
| Codex | Principal test engineer. Owns the UI-test track and eval tooling. |

Claude ⇄ Codex coordination happens in `docs/team-channel/` (one file per
message; see its README). Check it at session start and before touching
shared surfaces.

## Git Rules

- **Branch for anything bigger than a one-line tweak.** Names:
  `feature/…`, `fix/…`, `refactor/…`, `test/…`, `experiment/…`, `poi/…`
  (short-kebab).
- **Main always builds and passes the unit suite.**
- **Merge** = fast-forward after review + Rick's approval. If main moved,
  rebase the branch onto `origin/main` first.
- **Never** force-push, rewrite history on main, or delete branches/files
  without asking. File deletions go to the repo `.trash/`, not `rm`.
- **`~/dev/VideoScan` is Rick's checkout.** Never switch its branch, leave
  uncommitted changes, or build into its DerivedData. All autonomous work —
  Claude's agents AND Codex — happens in a `git worktree` with its own
  `-derivedDataPath`. This applies even when the tree "looks idle."
- Commit messages: conventional prefix (`feat:`, `fix:`, `test:`, `docs:` …),
  imperative, honest about scope.

## Testing Rules

- **Every bug fix ships with a regression test that was seen to fail on the
  broken code** (fix → test → revert fix → confirm test fails → restore →
  commit both, tagged `// regression:`). A test that never failed is theater.
- **Every feature ships with tests along five dimensions** (where applicable):
  1. Logic — ordinary unit tests
  2. Scale — iterates records? 100k synthetic records + explicit time budget
  3. Media matrix — opens media? mp4/h264, mov/prores, mkv, mxf, avi/dv fixtures
  4. Isolation — reads global state? add a poisoned-state test (never write
     to real prefs/paths in tests)
  5. Sensor — leave a regression sensor pinning the behavior at scale
- **Full unit suite green before requesting merge review.**
- Don't test other people's code (Vision, ffmpeg, AVFoundation) or SwiftUI
  layout. Test our logic: parsers, scoring, correlation, state machines,
  persistence.
- **No O(records) work in SwiftUI view bodies.** Ever.
- Tests run on bare-metal Apple Silicon, never GitHub-hosted runners (Swift
  Testing is unusably slow virtualized). GH CI does lint/metrics/TestDriver
  smoke only.

## Modes & Builds

- **Normal mode** (default): small steps, tests per the rules above.
- **RD (Rapid Dev)** — when Rick says "RD": build-only fast iteration, no
  auto tests; run the full suite as a start/end-of-day bookend.
- **Debug** config for iteration; **Release** for TestDriver/CI/perf/demos.

## Machines & Timing

Canonical schedule: `docs/team-operations/rick-availability.local.md`.
Highlights: the M4 Studio is Rick's during his working day (~11:30–18:00 ET);
prefer M5/M1 for heavy builds and evals; merges land in the 16:00–18:45 ET
window unless Rick says otherwise.

## Quick Reference

```bash
# New work
git switch -c feature/my-thing            # in a worktree if you're an agent

# Unit suite (from a worktree, isolated DerivedData)
xcodebuild test -project VideoScan/VideoScan.xcodeproj -scheme VideoScan \
  -destination 'platform=macOS' -only-testing:VideoScanTests \
  -derivedDataPath /path/to/isolated/dd

# After review + Rick's approval (ff-merge)
git push origin <branch>:main
```

When in doubt: ask Rick, and err on the side of a branch, a worktree, and a
test.
