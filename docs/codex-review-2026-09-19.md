# Adversarial review and nightly checkpoint — September 19, 2026

Rick requested ongoing adversarial review of Claude handoffs, tests for new
behavior, regression tests for fixes, and verification of nightly CI. Reviews
record the exact commit, applicable logic/scale/media/isolation sensors, machine,
configuration, and executed results. A scheduled job or successful build is not
test-pass evidence. M4 remains interactive; app-host and UI execution belongs on
an explicitly assigned M5/M1 unless Rick declares an M4 quiet window.

## Incoming work

Claude mailbox #1571 identifies `feature/angel-attention-memory` as the active
Phase 1 work. Await its finished commit and execution evidence before final
review. Requested the required 100k-record budget sensor in addition to the
proposed 10k skip simulation. Acknowledged #1571; sent findings in #1570/#1572
and ownership confirmation in #1573. CI/metrics WIP belongs to Codex.

## Committed Angel review

Read-only review of `4dbb1669^..d4477955` found these author follow-ups:

1. **Release build blocker:** `ArchiveAngelWholeJobTests` references
   `ArchiveAngelPlanWriter.injectedFailure`, which exists only under `#if DEBUG`.
   The default Release testbed cannot compile. Source-confirmed, not compiled.
2. **Cancellation consistency:** unfinished-row reclamation removes completed
   Balance/Access companions already catalogued as active workspace records.
   Cancel during a later step, or recover an interrupted row, and those records
   can point to removed files. Require a production-path regression.
3. **False-green testbed:** `.ready` alone does not establish companion success;
   production allows failed optional preparation. Assert requested outputs and
   step outcomes. Reject empty/invalid format and duration matrices.
4. **Notes:** substring deduplication can drop distinct notes; compare exact
   note identity. The final batch summary is appended after the last plan save,
   so the durable plan omits it.

Existing tests cover save ordering/failure, missing sources, stale-row cleanup,
buffer isolation, weak-center rejection, and real MP4 job failures. Still need
cancel-during-later-step coverage and evidence that opt-in full media/scale lanes
actually executed for the reviewed commit. These findings remain pending author
correction and re-review; they are not approvals of active WIP.

## Actual nightly evidence

All three fleet launchd schedules were loaded. September 19 local runs tested
`8f8e0745` in **Debug** and published failed results:

| Machine | Local schedule | Latest result |
|---|---|---|
| M4 | 02:00 | 7,845 pass, 2 fail, 61 skip; 1,134 seconds testing |
| M5 | 03:15 | 7,842 pass, 3 fail, 63 skip; 1,194 seconds testing |
| M1 | 04:30 | Build timeout, zero tests executed |

Both Donna assertion failures were subsequently corrected in `d995b992`; source
inspection confirms updated owner-address wording, but a fresh fleet run is
still needed. M5 also failed the Hallie latency budget. Its metrics falsely
labelled that ordinary assertion failure as a crash because display and method
names differed. M1 reported a 3,600-second build timeout; wall time included a
much longer interval, so do not attribute all elapsed time to compilation.

The local nightly script still uses Debug, contrary to the Release CI policy.
This checkpoint does not change the installed schedules or claim production
parity. M5/M1 had no active app/test jobs during the read-only probes.

[Latest push CI](https://github.com/musicalengineer/VideoScan/actions/runs/35470358822)
and [September 19 static nightly](https://github.com/musicalengineer/VideoScan/actions/runs/35433706555)
failed on the complex tuple sort in `GedcomFamilyGraph+CommonAncestry.swift:111`.
The hosted Swift 6.2 compiler timed out type-checking it.

## Codex repairs and regression gates

- Expanded the ancestry comparator into explicit rank/name/ID comparisons;
  independent QA found identical ordering semantics. Six focused synthetic Core
  tests passed in Release (1.713 seconds), including the 100k-person budget and
  36 ordering queries. Local Swift 6.4 verification does not substitute for the
  original hosted Swift 6.2 build. The real-tree sensor was explicitly excluded.
- Restored the accidentally removed nightly concurrency reporting, typecheck
  artifacts, CodeQL, disabled TSan, and strict lint jobs. Retained the new lint
  reporter in the correct job and fixed Periphery's index-store invocation.
- Added nightly workflow contract sensors and the missing CI workflow contract
  suite. The latter executes the actual test shell against mocked xcodebuild
  results, including missing canaries, incomplete runs and real failures.
- Corrected lint completion handling: completed strict violations retain their
  count; skipped, partial and failed scans remain unknown. SwiftLint's actual
  exit status is preserved because even a completion footer can precede a
  cache-save failure. Optional collector logs require explicit successful scan
  outcomes before publishing counts.
- Final exact CI preflight: **72 tests passed**, zero skipped, 3.405 seconds,
  including workflow failure-path and metrics regressions. These are headless
  checks, not app-test execution. Whitespace checks passed.
- Independent workflow review found no new blockers. Existing debt remains:
  the strict-concurrency counter reports zero when its build log is absent.

No commits, pushes, schedule installations or M4 app launches were performed.
Hosted CI and a current-commit fleet Release run remain required before a green
end-to-end claim.
