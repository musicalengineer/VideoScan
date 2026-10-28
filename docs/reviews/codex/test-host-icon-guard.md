# Codex review — test-host guard on MasterArchiveIcon

- Range: `main..fix/test-host-icon-guard`
- Credits spent: unavailable
- Tokens: 77582
- Finding count: 1
- Verdict: fix
- Run: 2026-10-28T17:47:57Z (cycle #162, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 1

**P1 — Symlink followed by `..` bypasses containment.** `VideoScan/VideoScan/Archive/MasterArchiveIcon.swift:113` removes `..` lexically before resolving symlinks, then apply/remove pass the original path to NSWorkspace.

Reproduction: create `<temp>/link → <outside>/child`, with `<outside>/victim` an existing folder. Check `<temp>/link/../victim`: the guard accepts `<temp>/victim`, but filesystem traversal reaches `<outside>/victim`. `fileExists` succeeds, allowing an NSWorkspace call for an outside target.

RED regression: create both trees in a disposable fixture, pass one tree as `temporaryDirectory`, and assert this path is refused. Resolve symlinks before collapsing `..`; refuse unresolved traversal. Foundation’s lexical normalization was confirmed; the full fixture and suites were not run because the sandbox is read-only.

The three scoped test files: read, no findings. The temp substitutions preserve m3 and GH #353’s assertions; the synchronous main-actor refusal-count check is race-free. Non-test behavior and sanitizer ordering are unchanged.

Verdict: fix

## Brief

# Codex review brief — test-host guard on MasterArchiveIcon

Workflow: a test must never change the Finder icon of a real volume or folder.

Range: main..fix/test-host-icon-guard (commit 5f21f6c8). Files:
VideoScan/VideoScan/Archive/MasterArchiveIcon.swift,
VideoScan/VideoScanTests/VolumeRoleTaxonomyMigrationTests.swift,
VideoScan/VideoScanTests/CatalogCutoverB21Tests.swift,
VideoScan/VideoScanTests/CatalogSQLiteLaunchNoJSONTests.swift.

Context: on 2026-10-28 a unit test (m3_clearMasterArchive…) hard-coded
"/Volumes/FamilyArchive"; clearMasterArchive() → MasterArchiveIcon.remove →
NSWorkspace.setIcon(nil) reached the real Master Archive volume on a Mac
where it is mounted. The guard refuses, before NSWorkspace, any path outside
the temp folder when TestEnvironment.isTestHost.

Attack these invariants:
1. Outside a test host behaviour is unchanged (apply and remove; the
   sanitizer early-return; fileExists ordering).
2. In a test host the refusal happens before ANY NSWorkspace call, for every
   path remove() iterates (root and volume) and for apply().
3. isInsideTemporaryDirectory/canonicalPath cannot be fooled: `..`, symlinks
   inside temp pointing out, /var vs /private/var, a sibling sharing the
   prefix, a relative path, an empty string, a path whose ancestors do not
   exist. A failure to canonicalise must refuse.
4. testHostRefusals: main-actor static; is the m3 count-delta check
   race-free (suite is @MainActor, test body synchronous)?
5. Test changes: do m3 and GH #353 still prove what their names say with
   temp paths (resolvedMasterArchiveTarget, writeDesignation target = root's
   parent)?
Out of scope: a general test-host write guard for other archive writers (to
be filed separately). Do not explore outside these files.

## Output contract
First line of your answer exactly: `Credits spent: <amount> | Finding count: <N>`
Then findings (file:line, failure scenario, severity), then a line `Verdict: <merge | fix | block>`.
