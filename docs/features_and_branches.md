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

- **Worktrees and /tmp are fine for an agent's *private* work** —
  research scripts, sandbox experiments, diagnostic dumps, brainstorms
  Rick will not touch. Use them freely there.
- **For *shared* work that Rick will build, test, or merge: never
  leave a worktree alive on a branch Rick needs to check out.**
  Worktrees lock branches; Rick uses `git checkout` in his
  `~/dev/VideoScan` shell as his primary flow.
- **The rule:** if the work crosses into Rick's hands, push the
  commits and remove the worktree before telling him it's ready.
- **Critical rule: commit + push + remove the worktree as soon as
  the build finishes.** Then Rick can check out and build the branch
  the normal way. Leaving a worktree alive blocks his workflow.
- **Pattern:** `git worktree add /tmp/vs-<my-id> <branch>` plus
  `-derivedDataPath /tmp/vs-<my-id>-dd` for builds. The moment the
  build is done and committed, `git worktree remove /tmp/vs-<my-id>`
  and `rm -rf /tmp/vs-<my-id>-dd`.
- **Never push an empty branch ref.** Always commit before push, or
  the user gets an empty branch and is confused. If you need to push
  before commit (you don't, this is a footgun), at least say so.
- **Pgrep guard before xcodebuild test/build is still useful as
  courtesy** between two agents:
  ```
  until ! pgrep -x xcodebuild >/dev/null && \
        ! pgrep -f VideoScanTests.xctest >/dev/null && \
        ! pgrep -f VideoScanUITests-Runner >/dev/null; do
    sleep 15
  done
  ```

**Why the worktree matters at all** (still useful in some cases):
- See `~/.claude/projects/-Users-rickb-dev-VideoScan/memory/feedback_two_claudes_coordination.md`
  for past incidents where shared working tree caused silent test
  failures from another agent's uncommitted files.
- But Rick's primary workflow is `git checkout <branch>` in his own
  shell, build in Xcode. Worktrees should never block that.

## Logging

When you introduce a new feature or wire up a new code path, add logs.
Without them, agents working remotely cannot see what the user clicks
or where the code reaches.

**Convention:** Apple `Logger` (`import os`).

```swift
import os

private let log = Logger(
    subsystem: "Rick-Breen.VideoScan",
    category: "identifyfamily"   // pick a per-feature category
)

log.info("Load Existing Run: name=\(name, privacy: .public)")
log.debug("Parsed \(parsed) clusters, rejected \(rejected)")
log.error("Failed to copy \(src.path, privacy: .public): \(error)")
```

**Categories already in use (extend as needed):**
- `identifyfamily` — clustering, naming, promotion
- `personfinder` — Find Person scans, engine dispatch
- `scan` — Catalog scans, ffprobe, walking
- `combine` — A/V muxing
- `archive` — Archive tab and disposition lifecycle

**What to log:**
- User actions (button click, folder pick, file load).
- State transitions (idle → scanning → reviewing).
- Filesystem writes (created POI X, copied N files to Y).
- External-process kickoffs and exit (subprocess pid, exit status).
- Anomalies that aren't fatal (parser rejected row N, file size 0).

**What NOT to log:**
- Loop bodies running on every frame, every face, every byte.
- Anything that runs more than a few times per second.
- Sensitive data in `.public`. Default is `.private` (redacts in stream
  output for non-developers); use `.public` only for non-sensitive
  identifiers like POI names that you and the user already share.

**How agents stream remotely:**

```
log stream --process VideoScan \
  --predicate 'subsystem == "Rick-Breen.VideoScan"' \
  --style compact
```

User-facing in-app console (the existing `dashboard.log(msg)` pattern,
or per-model `consoleLines`) is for the user. The OSLog stream is for
the agent. Most user-visible actions should hit both.

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
