# Family Tree cache lifecycle hardening

Branch: `fix/tree-cache-lifecycle`, based on `7fd31868`.

Rick assigned the remaining cache follow-ups to Codex; Claude reviews them.
Keep the window-owned tree model and the rename to `FamilyTreeView`.

## Changes

- The view calls `prepareForAppearance`, the same async path used by the new
  regression tests. Unchanged source/settings retain the graph and selection;
  CyberBrain still refreshes on return.
- The appearance task observes all four speaker/owner defaults. Changed settings
  flow as one captured snapshot into the existing loader and launch-bundle cache.
  Ordinary tab switches do not enter the graph loader. Settings changes may
  reload the compiled graph; they are not a per-appearance operation.
- Production bookmarks follow the configured GEDCOM directory. Explicit test
  stores remain isolated. Offline transitions clear the visible bookmark set;
  returning online reloads it. Read-only sources cannot persist bookmark edits.
- While a source replacement retains old cards onscreen, their bookmark toggles
  are rejected until the replacement installs. Old GEDCOM pointers must never
  be saved into another archive's bookmark file.

## Verification / review handoff

Swift frontend syntax parsing and `git diff --check` passed. These are NOT
typechecking or passing app tests. Xcode startup was blocked by the session's
sandbox access to CoreSimulator; no app or UI tests were launched on Rick's M4.

Five new tests in `FamilyTreeModelReuseTests` exercise warm retention, an
explicitly promoted replacement generation, externally written notes, changed
owner pin, archive bookmark rebinding/access isolation, and ten warm returns
over 100,000 people with a two-second total budget. A real loader-entry counter
also pins zero graph reloads on those warm returns.

Claude: review the diff and run `FamilyTreeModelReuseTests`,
`FamilyTreeBookmarksTests`, `FamilyTreeRecompileButtonTests`, and
`FamilyTreeNotesTests` on an available M5/M1 before landing. Tests remain
unexecuted at this handoff. No claim of merge readiness until that evidence.

Scope remains explicit reload/recompile for externally replaced GEDCOM files;
this change does not introduce filesystem watching. `noteAuthor` still captures
the owner at model initialization; that independent attribution refresh issue
is not resolved here.
