# Invariants: what the nightly adversarial review attacks

One file per area. `tools/adversarial_nightly.py` reads them to decide what is
in scope each night and to build the reviewer's brief. Design:
`nightly_adversarial_review_design_2026-10-01.md` (docs/, or docs/design/ after the reorg).

## File shape

```
---
tier: data-risk          # or: truth
paths:
  - VideoScan/VideoScan/Archive/**
  - VideoScan/VideoScanCore/Sources/VideoScanCore/ArchiveFixity.swift
---
# Title

## Invariants
1. **ARCH-1** One sentence a reviewer can try to break.

## Known and accepted (do not report)
- A deliberate limitation, with who accepted it.
```

- `tier: data-risk` — a miss can lose or corrupt family media, the archive or
  the family record (docs/source_layout.md, "Data-risk code"). Reviewed at
  effort `xhigh`.
- `tier: truth` — a miss makes the app say something false (Hallie answers,
  dates, genealogy). Reviewed at effort `high`.
- `paths` are repo-relative globs: `*` stays inside one folder, `**` crosses
  folders. A file may match more than one invariants file; data-risk wins the
  bucket.
- Invariant IDs are stable. Never renumber; retire one by striking it through
  and saying why. Finding fingerprints include the ID.

## The sensor

`tests/test_invariants_coverage.py` fails when a Swift file in a data-risk
folder writes (FileManager mutations, `write(to:`, `CyberBrainWriter`, the
POSIX rename/unlink calls, `AtomicFilePublish`) and no invariants file's
`paths` covers it. Fix it by adding the glob (and an invariant if the file
writes something new) — never by narrowing the sensor.

## Sources

Seeded 2026-10-01 from the codex briefs and review docs (#230 filing, #235
map birth rule, Refile r1–r6, Archive Update, Promote dates and lock, fixity
#1721, rename backups, dates resolver, the 9/28 day bundle),
docs/source_layout.md and the project's data-safety rules.
