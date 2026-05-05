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

## Worktree policy

**`~/dev/VideoScan` is Rick's primary workspace.** He builds, launches,
and iterates here using `git checkout <branch>`. This directory must
always be clean and switchable — no agent should leave uncommitted
changes, locked branches, or stale state that interferes with Rick's
ability to `git checkout` freely.

**Agents use worktrees for everything that doesn't need Rick in the
loop.** This includes:
- Unit/regression test development and execution
- Background automation (linting, coverage, diagnostics)
- Research scripts, sandbox experiments, brainstorms
- Any work on a branch that Rick isn't actively building/launching

**Worktrees are NOT for Rick's rapid-dev loop.** When Rick is doing
build-launch-tweak cycles, he works in `~/dev/VideoScan` on the
branch directly. Never ask Rick to build or launch from a `/tmp`
worktree path — that's confusing and breaks his flow.

**Think of it this way:**
- Rick's hands on the keyboard → `~/dev/VideoScan`
- Agent working autonomously → worktree

### Worktree mechanics

A worktree is a second checkout sharing the same `.git` database.
Commits made in the worktree appear in `git log` from either
directory. It's not a copy or clone — it's another window into the
same repo.

- **Location:** `~/dev/worktrees/vs-<purpose>` for anything meant to
  persist across sessions. `/tmp/vs-<id>` for throwaway work.
- **DerivedData:** Always use `-derivedDataPath` to isolate builds:
  `~/dev/worktrees/vs-<purpose>-dd` or `/tmp/vs-<id>-dd`.
- **Branch locking:** A worktree locks its branch — no one else can
  check it out. This is why agents must never worktree a branch Rick
  needs.
- **Cleanup:** `git worktree remove <path>` when done. If you just
  deleted the directory, `git worktree prune` tidies the bookkeeping.

### Handoff from worktree to Rick

When agent work is ready for Rick to test:
1. Commit and push the branch from the worktree.
2. `git worktree remove <path>` and `rm -rf <dd-path>`.
3. Tell Rick the branch is ready — he checks it out normally.

Never leave a worktree alive on a branch Rick needs. Never push an
empty branch ref — always commit before push.

### Courtesy guards between agents

```
until ! pgrep -x xcodebuild >/dev/null && \
      ! pgrep -f VideoScanTests.xctest >/dev/null && \
      ! pgrep -f VideoScanUITests-Runner >/dev/null; do
  sleep 15
done
```

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
