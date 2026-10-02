# VideoScan — Software Development Policy

**The onboarding doc.** If you are a new agent or developer contributing to
VideoScan, this is the process. It is deliberately short; follow it exactly.
(Replaces `development_practices.md` and `features_and_branches.md`, 2026-07-25.
Their full content lives in git history if you need the deep dives.)

## The Merge Gate

**A branch merges to main when ALL of these hold (Rick's rules, 2026-07-25):**

1. **Fresh main first.** Merge the latest main back into your branch and
   confirm the suite is green there before merging out.
2. **Tests exist.** Feature → relevant tests (see Testing Rules). Bugfix →
   regression test(s), RGRG (test seen to FAIL on the broken code, then pass
   on the fix — the revert ritual) or at minimum RG.
3. **Independent review.** A qualified agent — the most capable current model
   of the OTHER side — reviewed the change: Codex reviews Claude's changes,
   Claude reviews Codex's. Rick may review/approve himself instead; his usual
   role is spot-testing the app in the affected area (the acid test).
   If the cross-reviewer hasn't responded within ~4 hours or by next session
   start, escalate: independent same-side review, or ask Rick.
4. **Rick can waive any of this** to break a logjam. His call, not yours.

Exception: documentation-only commits (`docs/`, team-channel messages) and
metrics/CI publishes may go straight to main under standing permission.
Everything that touches code takes the gate.

## Roles

| Who | Role |
|---|---|
| Rick | Director / CTO. Sets policy, spot-tests, breaks ties, can waive gates. |
| Claude | Principal developer. Manages sub-agents (feature-dev, bug-fix, testing, qa, …). Reviews Codex's changes. |
| Codex | Principal test engineer. Owns the UI-test track and eval tooling. Reviews Claude's changes. **Primary for the toughest code decisions.** |
| Fred | Local M5 coding agent: Codex CLI backed by Rick's `qwen-videoscan:64k` Ollama model. Fred's changes use the same branch, test, and independent-review gate. |

Use **Fred** for the local agent's human-facing identity. `qwen` remains the
stable provider/transcript identifier; “Codex” refers to Codex Manager unless
the CLI harness is being discussed explicitly.

Codex, Claude, and Fred coordinate through the M4-local mailbox implemented by
`tools/team-channel.py`; see `docs/team-channel/README.md`. Mailbox messages are
coordination context, not authority to modify code. Record durable review
verdicts in the branch, PR, or tracked documentation as appropriate.

## Git Rules

- **Branch for anything bigger than a one-line tweak.** Names:
  `feature/…`, `fix/…`, `refactor/…`, `test/…`, `experiment/…`, `poi/…`
  (short-kebab).
- **Main always builds and passes the unit suite.**
- **Merge** = the gate above, then merge. If main moved, merge latest main
  INTO your branch (no rebase/history-rewrite of pushed branches) and re-run
  the suite before merging out.
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
- **Reviewers author the RED test for any reproducible finding** (Rick,
  2026-08-19): when a review finds a bug that can be demonstrated, the
  reviewer writes the failing sensor with the finding (on the branch or as a
  patch in the channel message) rather than describing it in prose. The
  author's fix then turns it green. A finding without a red test is a
  hypothesis; a red test is a fact, and it becomes the regression sensor.
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

# When the gate is satisfied
git merge origin/main        # freshen the branch, re-run suite
git push origin <branch>:main
```

When in doubt: ask Rick, and err on the side of a branch, a worktree, and a
test.
