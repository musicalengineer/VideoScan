---
tier: data-risk
paths:
  - VideoScan/VideoScan/Volumes/VideoScanModel+RetireVolume.swift
  - VideoScan/VideoScan/Volumes/VideoScanModel+DeleteScanTarget.swift
  - VideoScan/VideoScan/Volumes/VideoScanModel+ScanMerge*.swift
  - VideoScan/VideoScan/Volumes/VideoScanModel+VolumeLifecycle.swift
  - VideoScan/VideoScan/Volumes/VideoScanModel+VolumeRenameMigration.swift
  - VideoScan/VideoScan/Volumes/VideoScanModel+VolumeRoleMigration.swift
  - VideoScan/VideoScan/Volumes/VolumeCompare.swift
  - VideoScan/VideoScan/Volumes/ScanCheckpoint.swift
  - VideoScan/VideoScan/Volumes/ScanJobsStorage.swift
  - VideoScan/VideoScan/Volumes/DiscoveryAudit.swift
---
# Volumes: retiring a volume, deleting a scan target, scan merge, migrations, compare/rescue

## Invariants
1. **VOL-1** Retire Volume and Delete Scan Target remove catalog records only — never a file on any volume.
2. **VOL-2** Only the named volume's or target's records are removed. Matching is by volume identity (UUID) or an exact root path with a separator — never a bare prefix (`/Volumes/X` must not match `/Volumes/X 1` or `/Volumes/XY`).
3. **VOL-3** A whole-volume removal logs START/OUTCOME with counts and leaves the catalog recoverable (snapshot or undo) until the save is acknowledged.
4. **VOL-4** A scan merge never drops the records of files that are merely unreachable (offline ≠ deleted); a moved file re-attaches to its record by identity and is never duplicated; user data on a record (dates, notes, stars, dispositions) survives a re-scan.
5. **VOL-5** Rename and role migrations are idempotent (running twice changes nothing the second time) and never change a record's identity or its user data.
6. **VOL-6** Scan state and reports (checkpoints, job storage, discovery audits, CSV exports) are written atomically to App Support or Logs, never onto a scanned volume.
7. **VOL-7** Compare's rescue copy never overwrites an existing file and never modifies the source.

## Known and accepted (do not report)
- A checkpoint lost in a crash costs a re-scan, not data.
- Volume roles (MASTER / new / scratch / retired) are Rick's labels; the app does not infer them.
