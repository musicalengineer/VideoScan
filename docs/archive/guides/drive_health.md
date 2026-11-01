# Drive Health

Companion to **Relocate Volume** — surfaces real SMART data per scan target so
the manual Reliability / Trust decision (in the Volumes window editor) is
informed rather than guessed.

## Why it exists

Rick has a fleet of aging external HDDs (Mini2TB is dying mid-session as of
2026-05-30), assorted SSDs, and internal NVMe. The Volumes editor already
has `purchaseYear` and `trust` text fields — Drive Health pulls SMART so
those fields can be set with confidence.

Trust changes are **never** automatic. Drive Health makes a suggestion;
the user clicks `Update Trust` to apply.

## Architecture

```
DriveHealthProbe (actor)            ← in-session cache by /dev/diskN
  ├─ resolveDevice (mount → diskN, protocol, mediaTech)
  │     uses /usr/sbin/diskutil info -plist
  ├─ probe (SMART data)
  │     uses /opt/homebrew/bin/smartctl -a -j
  │     fallback /usr/sbin/system_profiler SPNVMeDataType -json
  │     for Apple-Fabric internal NVMe when smartctl returns nothing
  ├─ parseSmartctlJSON  (pure, tested with fixtures)
  ├─ parseSystemProfilerNVMe (pure)
  └─ returns DriveHealthSnapshot

DriveHealthSnapshot.recommendation  ← pure heuristic over the snapshot
  → .healthy / .watch / .planToRetire / .retireNow
```

All shell-outs go through the existing `ProcessRunner` helper — no new
subprocess-spawning patterns introduced. `smartctl` lives at
`/opt/homebrew/bin/smartctl`; missing binary surfaces a friendly
*"brew install smartmontools"* warning rather than crashing.

## Recommendation heuristic

| Signal                                          | Result          |
| ----------------------------------------------- | --------------- |
| `smart_status.passed = false`                   | retire now      |
| HDD reallocated sectors > 100                   | retire now      |
| HDD pending sectors > 5                         | retire now      |
| HDD offline uncorrectable > 0                   | retire now      |
| HDD reallocated sectors > 0                     | plan to retire  |
| HDD power-on years > 6                          | watch           |
| SSD/NVMe available_spare < 10%                  | retire now      |
| SSD/NVMe percentage_used > 85%                  | retire now      |
| SSD/NVMe percentage_used > 70%                  | watch           |
| otherwise                                       | healthy         |

Reasons are written in Rick's voice (no SMART jargon — guarded by
`test_friendlyTone_recommendationReasonsAreInPlainEnglish`).

## UI surfaces

1. **Inline card** in the Volumes editor's Hardware section. Compact
   one-liner with disclosure for full details, Re-probe button, and a
   soft `[Update Trust]` prompt when the recommendation diverges from
   the current Trust value.

2. **Standalone sheet** launched from the volume row context menu
   (`Show Drive Health…`). Same `DriveHealthCard` content with a larger
   modal frame.

## Error modes

The probe **always** returns a snapshot. Failures populate
`probeWarnings` with plain-English explanations:

| Failure                                           | Warning                                                          |
| ------------------------------------------------- | ---------------------------------------------------------------- |
| smartmontools not installed                       | *"…brew install smartmontools to enable Drive Health."*          |
| USB bridge doesn't pass SMART                     | *"This drive's USB enclosure doesn't pass SMART data through…"*  |
| smartctl exit code 2 / drive unresponsive         | *"Drive didn't respond to a SMART query."*                       |
| Apple Fabric NVMe (smartctl no support)           | falls back to `system_profiler SPNVMeDataType -json`             |

When no actionable signal is available, the recommendation falls back to
*"Couldn't read SMART data — judge by age and use."* — still healthy by
default rather than crying wolf.

## Caching

Snapshots are cached per `/dev/diskN` for the duration of the app
session. Re-probe button (or `forceRefresh: true`) busts the cache for
that one device. No on-disk persistence — Drive Health is a live view,
not a journal.

## Files

- `VideoScan/VideoScan/DriveHealth.swift` — model + actor + parsers
- `VideoScan/VideoScan/DriveHealthView.swift` — `DriveHealthCard` + `DriveHealthSheet`
- `VideoScan/VideoScan/VolumesWindow.swift` — integration points (inline
  card in editor, context menu item, sheet plumbing)
- `VideoScan/VideoScanTests/DriveHealthTests.swift` — 16 unit tests
- `VideoScan/VideoScanTests/Fixtures/smartctl_hdd_seagate_ironwolf.json`
  — real HDD output (serial redacted)
- `VideoScan/VideoScanTests/Fixtures/smartctl_nvme_apple.json`
  — real internal NVMe output (serial redacted)
