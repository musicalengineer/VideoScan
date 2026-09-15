# Overnight findings — 2026-09-14

Written while Rick was away. **Nothing here was merged to `main`.** Fixes that
exist are on their own branches; everything else is a finding awaiting his call.

Context: the day's P0 (`docs/incident_2026_09_14_sandbox_rename_wedge.md`) was
fixed and merged as `34aeda64`. Rick then spot-tested, reported two things, and
handed the fleet over for the night with one standing instruction:

> "we always must log at critical points so we can see what was happening when
> something bad happened or we got hung"

---

## 1. Promote UX — "app blocks when promoting 10 files, user must sit and watch"

**Not a hang, and not the P0 fix.** Sampled the live process mid-promote
(`sample 22280 3`) during a real 21-file / 263 GB batch:

| top of stack | samples |
|---|---|
| `read` | 1213 |
| `write` | 732 |
| `AccelerateCrypto_SHA256_compress` | 482 |
| `pread` | 150 |
| all SwiftUI / AttributeGraph | ~60 |

The main thread was **64 % idle** in `mach_msg2_trap`. No `atomic publish SLOW`
or `STALLED` lines fired (thresholds 1 s / 10 s, both `.notice`/`.error` and
therefore persisted). The new `F_FULLFSYNC` work is invisible in the profile.

So the app is doing exactly what it should: copying and SHA-256 verifying
263 GB. The verification doubles the reads. That is inherently minutes of work.

Three separable issues fall out:

### 1a. The MFO window is already non-modal — the complaint is saturation, not blocking
`MediaFileOperationsWindow.swift:7` — *"ONE non-modal window for every
file-by-file operation."* Rick is not locked out of the UI; the machine is
saturated with I/O. Any fix is about throughput and feedback, not modality.

### 1b. 🔴 The promote logs nothing per file — minutes of silence mid-batch
`PromoteToArchiveJob.swift:236-302`. Per-file `model.log` calls exist ONLY for
the exceptional paths (adopted / skipped / FAILED). The **normal** path logs
nothing between the batch begin line and the batch summary.

Observed live: one begin line at 20:53:29 for all 263 GB, then **five minutes of
complete log silence** while a single large file copied. From the log alone,
that is indistinguishable from a hang — which is the exact failure mode that
cost two days this week.

**Fix:** a begin line per file before the copy starts (`Promote: copying
<name> (<size>) → <dest>`) and an end line with elapsed time. This is Rick's
rule applied literally: log that you are ENTERING the long operation.

### 1c. 🟠 CatalogSync re-hashes 360 MB every ~20 s, contending with the promote
`CatalogSync.computeManifestLines` (`CatalogSync.swift:604`) SHA-256 hashes
**every file in scope on every refresh**. Measured from the live
`manifest.sha256`: **241 files, 0.36 GB**, re-hashed in full each time.

During the promote it fired every ~18-20 s; this session's log has **478**
manifest writes — on the order of **170 GB of redundant hashing**, on a
`.utility` queue, while the promote is itself SHA-256 verifying 263 GB. They
contend for both I/O and the crypto units.

Nearly all 241 files never change — the churn is `catalog.json` (63 MB) and
`catalog.json.prev` (63 MB); the rest is POI photos and a compiled tree.

**Fix:** cache hashes keyed by (path, size, mtime) and re-hash only what
changed. To be clear about severity: the refresh is correctly coalesced
(`manifestRefreshRunning` / `manifestRefreshDirty`) and correctly off-main
(`Task.detached(.utility)`) — it is wasteful, not wrong. **This is catalog
integrity code; it needs Rick's approval, not an overnight patch.**

---

## 2. Dialog logging — FIXED on `fix/volume-rename-notice-logging`

Chasing Rick's "Not Now" report I grepped `videoscan.log` for the whole session
and found no trace of the volume-rename notice: it logged **nothing** when it
appeared or when the user answered it. Undo was the only branch with logging.

Now logged at both ends, to the unified log and the write-through `appLog`:
SHOWN for all three tiers (ask / migrated / refused ×2) with the counts behind
the decision, plus CHOICE Update, DISMISSED (Not Now / Esc), CHOICE Rescan.

`.notice`, not `.debug` — **debug is streamed live but NOT persisted by the
unified log**, so it is useless for reading after the fact, which is the entire
point of these lines. That trap is now recorded in the logging convention.

---

## 3. The "Not now / greyed out" dialog — NOT A BUG

`ArchivedWhatNextSheet.swift` — "Archived — what next?", promote-and-prune
stage 2. `Button(applyTitle) {}.disabled(true)`, with the caption *"Dry run —
Apply arrives after a few days of real batches."* That is Rick's own ruling of
2026-09-12 (`docs/promote_and_prune_workflow_design.md §"The sheet"`). Apply is
not gated on anything clickable; it stays disabled until someone removes that
line deliberately.

Worth knowing: the attestation radios ARE live — they persist immediately via
stage 1's `recordAttestation` and the plan recomputes after each answer. Only
the Trash step is deferred.

**My error along the way:** I grepped `"Not Now"` case-sensitively, found the
volume-rename alert, and confidently identified the wrong dialog. Rick's is
`"Not now"`. The useful by-product was §2.

---

## 4. The P0 oracle — full battery on the fixed main

Three full rounds of `VideoScanTests` on **M5 and M1 independently**, both on
`34aeda64`, both freshly rebooted with a verified baseline of **0 wedges**.
This is the workload that produced four wedges on 09-13 and one on 09-14.

Each round asserts a real test count, not just an exit code — the 09-14 A/B on
M1 reported "0 wedges, both arms" while all four runs had died on
`childPID > 0` without executing a single test. A run that can silently no-op
proves nothing.

*Results appended when the runs complete.*

---

## 5. Spot-test tally on `34aeda64` (Rick, this evening)

Six launch/quit cycles — 3 Debug, 3 Release — **every one reaching
`Termination complete`**, 551-674 ms, no `publishes still in flight at quit`,
zero wedged processes on M4. Release matters most: it is the configuration that
wedged on 09-13, where the app logged `app quitting` and never reached
`Termination complete`.

Exercised along the way: a 3 GB promote, a 263 GB promote, Tidy, attestations,
311-file manifest writes, and filmstrip publishes from the detached sweep
daemon — all through the new publish path, with no slow or stalled line.
