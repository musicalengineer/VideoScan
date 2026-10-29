# Codex review — disk_check closing 3

- Range: `f4a1f758..8c2f6e8c`
- Credits spent: unavailable
- Tokens: 29958
- Finding count: 2
- Verdict: fix — Boot-container protection and remount-failure reporting have reproducible gaps.
- Run: 2026-10-29T20:10:18Z (cycle #171, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 2
Verdict: fix — Boot-container protection and remount-failure reporting have reproducible gaps.

1. **P1 — Externally booted containers are eligible for unmount.** `scripts/disk_check.py:80–81,112` treats external hardware as sufficient eligibility without identifying the active boot container. When booted from USB, `--offline` attempts to unmount that container; `--repair Boot` also selects it. A partial unmount can affect sibling volumes even if the system volume refuses.
   **RED:** `test_external_boot_container_is_protected` supplies an external USB container with a System volume mounted at `/`; expected selection `[]`, actual selection `[disk3]`.

2. **P2 — Logging failure discards `leftUnmounted`.** `scripts/disk_check.py:204` calls fallible logging before assigning the outcome at line 206. If remount fails and logging raises—for example, a full log filesystem—`check_one` raises instead of returning `leftUnmounted`. `main` then misclassifies it as `notChecked`; subsequent logging can abort before notification.
   **RED:** `test_failed_mount_returns_left_unmounted_even_if_logging_fails` mocks `mountDisk` returning 1 and `log` raising `OSError`; expected `leftUnmounted`, actual uncaught exception.

Existing suite: **30 passed**. Both additional mock regressions ran RED in memory; no files changed or disks touched.

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
