# Codex review — disk_check closing 4

- Range: `f4a1f758..bc58f470`
- Credits spent: unavailable
- Tokens: 34433
- Finding count: 1
- Verdict: fix — logging failures can suppress required failure notifications.
- Run: 2026-10-29T20:13:26Z (cycle #172, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 1
Verdict: fix — logging failures can suppress required failure notifications.

- **P2 — Failure notification depends on successful logging.** `scripts/disk_check.py:264` calls `log()` before recording the failure and reaching `notify()` at line 272. If the log volume fills or becomes unwritable after verification, a `problemsFound` or `leftUnmounted` result raises out of `main()` without notifying Rick. The output append at line 267 has the same problem.

  **RED test executed:** mocked discovery of FamilyArchive, `check_one()` returning `problemsFound`, and `log()` raising `OSError("log volume full")` on the result line. Asserted that `notify()` was called: **FAIL**, notification list empty. Failure reporting should survive logging errors.

Existing suite: **32 tests passed**. All disk operations were mocked; no files changed.

- `tests/test_disk_check.py`: read, no findings.
- `scripts/install_disk_check.sh`: read, no findings; launchd invokes live mode.

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
