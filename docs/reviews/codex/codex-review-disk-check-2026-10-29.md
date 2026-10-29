# Codex review — disk_check

- Range: `f4a1f758..336715f2`
- Credits spent: unavailable
- Tokens: 48802
- Finding count: 3
- Verdict: block — Three reproduced failures violate disk-selection and remount safety invariants.
- Run: 2026-10-29T20:00:34Z (cycle #168, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 3
Verdict: block — Three reproduced failures violate disk-selection and remount safety invariants.

1. **P1 — Unknown store metadata permits protected disks to be selected.** `scripts/disk_check.py:73–79,91` defaults missing information to external/non-image. If `diskutil info` fails for the boot store or a disk image, offline/repair selection admits it.
   **RED:** Parse a boot container named `Data` with empty store metadata; assert repair selection returns nothing. Actual: selects `disk3`.
   `tests/test_disk_check.py:59–61` explicitly endorses this unsafe default. Require positive external/non-image evidence.

2. **P1 — Protected identifier collisions select the wrong container.** `scripts/disk_check.py:99–106` removes protected containers before checking target ambiguity. Given internal `disk3` and external `disk13` containing a volume named `disk3`, `--repair disk3` selects and potentially repairs `disk13`.
   **RED:** Assert that selection refuses this fixture. Actual: returns exactly `disk13`, passing the single-container gate. Resolve identifiers and ambiguity before eligibility filtering.

3. **P1 — Exceptions bypass remount and failure notification.** `scripts/disk_check.py:157–164,198` has no `finally` around unmount/check/remount. An exception launching or decoding verification after successful unmount exits without mounting; exceptions from repair have the same effect. Main also bypasses its failure notification.
   **RED:** Mock successful unmount, then `OSError` from verification; assert `mountDisk` was attempted. Actual calls: `unmountDisk`, `verifyVolume`. Guarantee remount after every unmount attempt and report remount exceptions as `leftUnmounted`.

`scripts/install_disk_check.sh`: read, no findings; scheduled arguments use live mode.

Validation: **16 existing tests passed; 3 adversarial tests failed as expected.** All disk commands were mocked; no files changed.

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
