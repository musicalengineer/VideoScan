# Features and Branches

Project policy for how Claude agents (4-6, 4-7, future) coordinate work
across branches. Lives in `docs/` so it's tracked in git and visible to
every agent.

## Branching policy

- **Anything bigger than a one-line tweak gets its own branch.**
  Bug fixes, new features, refactors, experimental work, automation
  scripts that mutate code — all go on branches.
- **Branch names are descriptive.** Pattern: `feature/<short-kebab>` for
  features, `fix/<short-kebab>` for bug fixes, `refactor/<short-kebab>`
  for cleanups, `experiment/<short-kebab>` for prototypes that may
  not land. Examples already in this repo:
  - `feature/find-av-pair`
  - `feature/identify-family-progress`
  - `refactor/code-quality-may02`
- **Main is for things Rick has tested.** Agents do not push directly
  to main. The merge-to-main step happens after Rick has built and
  spot-checked the branch's app behavior.
- **Periodic merges.** When a branch's work is verified, fast-forward
  merge it to main. `git push origin <branch>:main` works for
  ff-clean cases. If there are conflicts with main (because another
  agent moved main forward), rebase the feature branch onto
  `origin/main` first, then push.

## Two-agent coordination

When two Claude windows are active on this repo:

- **Use git worktrees, never share the working tree.** See
  `~/.claude/projects/-Users-rickb-dev-VideoScan/memory/feedback_two_claudes_coordination.md`
  for the gory why. Short version: agents stomping on the same checkout
  has caused silent test failures from one agent's uncommitted files.
- **Pattern:** `git worktree add /tmp/vs-<my-id> <branch>` plus
  `-derivedDataPath /tmp/vs-<my-id>-dd` for builds. Clean up after.
- **Pgrep guard before xcodebuild test/build:**
  ```
  until ! pgrep -x xcodebuild >/dev/null && \
        ! pgrep -f VideoScanTests.xctest >/dev/null && \
        ! pgrep -f VideoScanUITests-Runner >/dev/null; do
    sleep 15
  done
  ```
  Courtesy, not correctness — the worktree isolation is what keeps
  things sane.

## Automation on branches

Scripts that *don't change code* (diagnostic dumps, catalog scans,
embedding computations, classifier training) can run from anywhere
under `/tmp/` or `~/dev/VideoScan/output/` without a branch.

Scripts that *commit changes* — even auto-formatting, even doc updates —
do their work on a branch, never on a checkout that's tracking main.

## When to merge to main

- Tests pass on the branch.
- Rick has built it and spot-checked the relevant feature in the app.
- For experiments: only after Rick decides the experiment is worth
  keeping. Failed experiments stay on their branch and may be deleted.

## When *not* to delete a branch

- An experiment is paused but not abandoned.
- Another agent might want to build on it.
- Rick hasn't said "you can delete it" yet.

When in doubt, leave the branch and ask.

## Quick reference

```bash
# Start a new feature branch
git fetch origin
git worktree add -b feature/<name> /tmp/vs-<id> origin/main

# Build with isolated DerivedData (Mac Studio)
cd /tmp/vs-<id>/VideoScan
xcodebuild -project VideoScan.xcodeproj -scheme VideoScan \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/vs-<id>-dd build

# Tests (unit only, skip UI tests' Accessibility issues)
xcodebuild test -project VideoScan.xcodeproj -scheme VideoScan \
  -destination 'platform=macOS' -only-testing:VideoScanTests \
  -derivedDataPath /tmp/vs-<id>-dd

# When done, after Rick has tested:
git push origin feature/<name>             # push branch
git push origin feature/<name>:main        # ff-merge to main (if clean)
git worktree remove /tmp/vs-<id>
rm -rf /tmp/vs-<id>-dd
```
