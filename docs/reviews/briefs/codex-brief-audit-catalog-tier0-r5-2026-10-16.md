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
