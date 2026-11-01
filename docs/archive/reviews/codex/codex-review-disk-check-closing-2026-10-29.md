# Codex review — disk_check closing

- Range: `f4a1f758..2afd4f30`
- Credits spent: unavailable
- Tokens: 26452
- Finding count: 3
- Verdict: fix — Three reproduced gaps permit unsafe offline checks or misreport check failures.
- Run: 2026-10-29T20:04:04Z (cycle #169, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 3
Verdict: fix — Three reproduced gaps permit unsafe offline checks or misreport check failures.

1. **P1 — Process detection fails open.** `scripts/disk_check.py:135`
   When `pgrep` exits 2 or 3, `videoscan_running()` treats the error as “not running.” Offline and repair modes proceed without establishing that VideoScan has stopped.
   **RED:** Mock `run()` with return code 2; invoke offline mode. Assert `check_one()` is never called. It is called.

2. **P2 — Volume names can break failure notifications.** `scripts/disk_check.py:131`
   A volume named `Rick "Archive"` inserts unescaped quotes into AppleScript. The notification command becomes invalid, and its failure status is ignored.
   **RED:** Call `notify('disk13 (Rick "Archive"): problemsFound')` with mocked `run()`; assert embedded quotes are escaped. Assertion fails.

3. **P2 — Zero checks report success.** `scripts/disk_check.py:237`
   If discovery returns no containers—including a parsed plist missing `Containers`—the script logs `ok=0 failed=0`, exits 0, and sends no notification.
   **RED:** Mock `discover()` to return `[]`; invoke live mode and require nonzero exit plus notification. Actual exit is 0.

`tests/test_disk_check.py`: read, no findings.
`scripts/install_disk_check.sh`: read, no findings; scheduled arguments select live mode.

Validation: 21 existing tests passed; all three additional mocked regression tests failed as described. No files changed or disks touched.

## Brief

# Codex brief — disk_check.py (scoped)

Workflow, in Rick's words: "check each disk's file system; fix one only when I say so."

Files (the only files in scope):
- scripts/disk_check.py
- tests/test_disk_check.py
- scripts/install_disk_check.sh

Context: macOS 27, APFS. External containers hold the family media archive
(FamilyArchive). `--repair` runs `diskutil repairVolume` on one container.
The weekly launchd job runs live mode only.

Invariants to attack:
1. No file-system write (repairVolume) unless: mode is repair, euid is root,
   exactly one external container matched by name, and a verify of the
   unmounted container in the same run did not come back clean.
2. Every unmountDisk attempt (success or failure, including partial) is
   followed by a mountDisk attempt; a failed remount always yields
   `leftUnmounted`, never success.
3. No outcome other than `ok` / `repaired` is counted as success; the process
   exits non-zero if any container failed, and failures notify.
4. The internal (boot) container and disk images are never unmounted or repaired.
5. A verdict of OK needs exit status 0 AND the "appears to be OK" text; any
   ambiguity is a failure, not a pass.
6. Offline/repair refuse while VideoScan is running.
7. Name matching cannot select the wrong container (e.g. a volume name equal to
   another container's diskN, duplicate volume names, substring matches).

Also look for: exceptions that skip the remount (e.g. discover() or run()
raising mid-loop), the launchd plist running a mode other than live, and
anything that reports a check as done when it was not.

**Output contract:**
```
Credits spent: <amount> | Finding count: <N>
Verdict: merge | fix | block — <one sentence>
```
Then findings ranked P0–P3 by data-loss risk, each with `file:line`, a
concrete failing scenario, and a RED test where possible. For every in-scope
file with nothing to report write "read, no findings." Do not explore outside
these files.
