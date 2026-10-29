# Codex review — disk_check closing 2

- Range: `f4a1f758..b2e5b6d9`
- Credits spent: unavailable
- Tokens: 33629
- Finding count: 2
- Verdict: fix — Two adversarial tests fail: protected-store eligibility and ambiguous verification output.
- Run: 2026-10-29T20:07:02Z (cycle #170, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 2
Verdict: fix — Two adversarial tests fail: protected-store eligibility and ambiguous verification output.

1. **P1 — Only the first physical store determines protection.** `scripts/disk_check.py:73–80` ignores every subsequent store. Reproduction: a container has an external USB first store and an internal second store. Selecting its unique name for repair succeeds; a failed verify then permits `repairVolume`. The same gap admits unknown or disk-image secondary stores. Require positive eligibility evidence for every store, or refuse multi-store containers.
   
   **RED observed:** `test_internal_second_store_is_protected`: expected no selection; received `disk13`.

2. **P1 — A member-volume OK can mask an incomplete container check.** `scripts/disk_check.py:118–119` accepts any occurrence of the OK substring. Reproduction: exit status 0 with stdout:
   ```text
   The volume A appears to be OK
   The container could not be verified completely
   ```
   This returns `ok`, counts as success, and suppresses failure notification. Require an unambiguous clean verdict for the checked container.
   
   **RED observed:** `test_conflicting_verdict_is_not_ok`: expected false; received true.

`tests/test_disk_check.py`: read, no findings. Existing suite: **25 passed**; supplemental in-memory tests: **2 failed**.

`scripts/install_disk_check.sh`: read, no findings. Scheduled arguments select live mode.

No files changed.

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
