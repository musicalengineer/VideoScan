# Codex review — Audit Catalog tier 0 r5

- Range: `572d74bb0..a8feb5787`
- Credits spent: unavailable
- Tokens: 90047
- Finding count: 2
- Verdict: fix — **a false Missing mark is still reachable on a later run.** An entirely unstamped first run cannot add Missing marks, but it can create unkeyed authority on a physical drive.
- Run: 2026-10-16T21:58:53Z (cycle #83, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 2

Verdict: fix — **a false Missing mark is still reachable on a later run.** An entirely unstamped first run cannot add Missing marks, but it can create unkeyed authority on a physical drive.

1. **P1 — Failed device identification creates fresh UUID-only authority (attacks 1/4).** [DeleteDuplicatesDrives.swift:326](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/DeleteDuplicatesDrives.swift:326) returns nil for `.unknown`; [CatalogAuditPlan.swift:285](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditPlan.swift:285) still creates a stamp, and [line 628](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditPlan.swift:628) treats its absent key as permission to prove by UUID alone.

   **Failure scenario:** first audit finds the file on physical drive A while DiskArbitration description fails; later, an older clone B with the same UUID but a different device path replaces A, and the absent file is marked Missing although it remains on disconnected A.

   This requires neither an r3 stamp nor the identical-enclosure residual. The existing unknown-device test starts with an already-keyed stamp; it does not test acquiring a stamp while identification fails. Therefore **“the first run writes keyed stamps for every present row” does not hold**. Unknown local-device identity should withhold marking authority.

2. **P2 — Filename-only reassignment retains authority without verifying the rename (attack 3).** [VideoRecord.swift:140](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/VideoRecord.swift:140): stamp `/d/a.mov`, assign `fullPath = "/d/b.mov"` without moving the file, then audit; the retained stamp permits Missing while `a.mov` remains. This is a setter-level reproduction; no production writer performing that sequence was established within the permitted scope.

The remaining attack checks:

- **1, keyed stamps:** holds for a DMG replacing a keyed drive: nil current key is refused at `CatalogAuditPlan.swift:629`. Different device-path keys are refused at line 633. No additional practical same-key case established beyond the declared residual.
- **2:** post-open binding holds for the examined substitution/replacement cases at `CatalogAuditPlan.swift:385`, `421`, and `465`; the gone proof checks pathname identity again at line 549. No additional ordering established beyond the excluded residuals.
- **3, decoding:** [VideoRecord.swift:798](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/VideoRecord.swift:798) and line 889 load path and stamp independently. Mismatched serialized values survive decoding; no in-scope production producer of that mismatch was established.
- **5:** decoding is another stamp assignment. [CatalogAuditJobTests.swift:601](/Users/rickb/dev/VideoScan/VideoScanTests/CatalogAuditJobTests.swift:601) checks one particular assignment spelling in the model half; it does not establish repository-wide writer exclusivity. Excluded DTO/clone/rescan implementations were not inspected.

`AuditSeenOn.swift`, the named tests/sensors, and MOPS-14: read, no additional findings. Reviewed `a8feb5787`; reproductions are source-derived. Tests were not executed; no files written.

## Brief

# Codex brief: Audit Catalog tier 0 — round 5 (device key + post-open binding)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~600 words. Say plainly whether a false Missing mark is still reachable. If what remains is P2 or declared residuals, say "merge" — Rick runs the first real audit on that word (it stamps and lists; it marks nothing until a second run).

**One sentence:** check that every catalog row on a connected drive still points at its file, and mark the ones that are gone as Missing.

**The rule (r3 + r4 closures, `docs/reviews/codex/codex-review-audit-catalog-tier-0-r3-2026-10-16.md`, `…-r4-…`):** a row is marked gone only when its folder is on the volume AND the physical drive the file was LAST SEEN on. `AuditSeenOn {volumeUUID, deviceKey?, mountFrom, seenAt}`; the key is Delete Duplicates' device-path digest (`DuplicateDrives.physicalDeviceKey`), nil for shares / disk images. No stamp → `neverSeenByAnAudit` (never marked). Both walks (`prove`, `seenOn`) run `boundToItsPath` right after the open: the lexical `lstat` link walk again + `fstat(fd)` dev+ino == `lstat(path)` dev+ino and a directory. A path change to another folder clears the stamp (`VideoRecord.fullPath.didSet`).

**Range:** `572d74bb0..a8feb5787` on `main` (the fix is `6036a989e`). Read with `git show a8feb5787:<path>`. Paths under `VideoScan/VideoScan/`.
- `MediaOps/CatalogAuditPlan.swift` — `CatalogAuditMountIdentity.of(fd:)` (+ `deviceKey`), `CatalogAuditDirectoryWalk.boundToItsPath`, `prove`, `seenOn`, `CatalogAuditProof.onTheVolumeLastSeen` / `onTheDriveLastSeen`.
- `MediaOps/DeleteDuplicatesDrives.swift` — `liveIdentityFresh(mountFrom:isLocal:device:)`, `physicalDeviceKey(mountFrom:isLocal:device:)` (the DiskArbitration read stays here).
- `VideoScan/VideoScanCore/Sources/VideoScanCore/AuditSeenOn.swift`, `VideoRecord.swift` (`fullPath.didSet` ~131–143).
- Tests: `VideoScan/VideoScanTests/CatalogAuditRound2Tests.swift` (23), `CatalogAuditJobTests.swift` sensors.
- `docs/practices/invariants/MediaOps.md` MOPS-14.

**Attack (prove with file:line or say it holds):**
1. The device key is a digest of the DiskArbitration device PATH. The same drive on another port/enclosure → a different key → "a clone? not marked" (refuse over guess, costs one run). Two identical enclosures on one port share a path (declared residual). Is there a case where a DIFFERENT drive gets the SAME key while carrying the same volume UUID, other than that residual? A DMG (no key) mounted at the path of a keyed drive?
2. `boundToItsPath` after the open in both walks: name an ordering of link substitution / folder replacement / unmount that survives both the re-walk and the fstat/lstat equality with the handle on the wrong directory, other than replace-and-replace-back between two syscalls.
3. `fullPath.didSet` clears the stamp on a folder change — can a writer set `fullPath` to the SAME folder with a different file name and then the row's file be elsewhere (rename on disk not applied)? Does any writer bypass the setter (direct storage, DTO decode of a moved row with an old stamp — `init(from:)` does not run didSet)? Can a catalog decoded from disk carry a stamp for a path the row no longer has?
4. r3-era stamps carry no device key and prove by volume UUID alone until re-stamped — on Rick's catalog no r3 stamps exist yet (no real run has happened), confirm the first real run writes keyed stamps for every present row.
5. Anything else that writes `auditSeenOn` besides the ONE stamp site and the didSet clear.

**Do only this:** findings against 1–5 (P1 first), each with file:line and a one-line failure scenario; then at most two P2/P3 one-liners. Out of scope: GH #323, GH #324 (sibling proof's own blind spot), Fix Links, nightly wiring, the freshness model, wording, declared residuals.

**Do not explore outside the files listed above and their tests.**


## Closure (Manager, 2026-10-16 — fix on main, see `git log --grep "codex r5 closed"`)

1. **P1 unidentified local drive → key-less stamp → UUID-only authority — closed.** `DuplicateDrives.deviceIdentification(mountFrom:isLocal:device:)` returns the key AND whether the drive was identified (one DiskArbitration read); `CatalogAuditMountIdentity.deviceIdentified`; `seenOn(at:)` writes NO stamp for a local device DiskArbitration cannot describe (`.unknown`). Shares and disk images stay identified-without-a-key by design. Pin `unidentifiedLocalDriveWritesNoStamp` (present but unstamped on an unknown drive; gone later on a described drive → never seen by an audit, no mark). Sensor pins the identification call and the guard. Honest note: this pin was written together with the fix, not shown red first; codex's source-derived reproduction is the red.
2. **P2 same-folder rename keeps the stamp — closed by the simpler rule:** ANY change of `fullPath` clears the stamp (`VideoRecord.fullPath.didSet`); a rename costs one run before marks. `aPathChangeClearsTheStamp` updated.

Confirmed by codex, no change: keyed stamps vs a DMG / a different device path; the post-open binding orderings; decoding loads path and stamp independently with no in-scope producer of a mismatch.

106 tests in 8 suites green on main (Debug). Round 6 brief: `docs/reviews/briefs/codex-brief-audit-catalog-tier0-r6-2026-10-16.md`.
