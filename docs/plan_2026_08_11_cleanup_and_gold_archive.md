# Plan — Reclaim the catalog (2026-08-11)

Written 2026-08-10 for tomorrow's session. Goal in Rick's words: *"get the
catalog down in size so it's easier to deal with and search"*, and don't
drag junk onto the new hardware.

## The sequencing constraint (read this first)

**Thursday 2026-08-12** brings a Promise Pegasus32 R4 (12 TB RAID) and a
Samsung 4 TB SSD (~3 GB/s). Migration must happen **after** the cleanup,
not before. Every junk gigabyte migrated costs twice — once to copy, once
to delete — and copying junk onto the Gold partition pollutes the archive
we're trying to establish. So:

| Day | Work |
|-----|------|
| Wed 8/11 | Cleanup Queue + duplicate collapse. Get the catalog small. |
| Thu 8/12 | Hardware arrives. Gold Archive partition, promotion, migrate. |

That ordering is the whole reason tomorrow is a cleanup day.

Today's TOTAL MEDIA footer says **6.8 TB gross / 3.8 TB unique**. The 3.0 TB
gap is the target. Confirm the split per bucket by hovering the footer
before starting — if `unanalyzedFiles` coverage is low, the real reclaim is
larger than 3.0 TB, not smaller.

---

## P0 — Full-content hashing — ✅ DONE 2026-08-11 (commit f7946624)

### Why it was the blocker

`FileHasher` implemented only `partialMD5` — a 64 KB head hash. Fine for
the footer's estimate and for *suggesting* duplicates; NOT sufficient to
authorize deleting a family video.

Failure mode: two distinct Avid MXF essence files from the same session
share a wrapper header and can be padded to the same length. Head hash +
size says "identical". Delete the wrong one and the footage is gone.

The fix — **segmented hash**, not full-file:

```
segmentHash = SHA256( head 1MB ‖ middle 1MB ‖ tail 1MB ‖ sizeBytes )
```

Three seeks instead of streaming 12 GB — milliseconds versus ~2 minutes
on a 12 GB file, which is what makes a whole-catalog pass take minutes.

**CORRECTED 2026-08-12** (codex #320, #338). This paragraph originally
called the collision risk "negligible" and proposed full-hashing the
survivor ONLY. Both were wrong, and this document was still saying so
after the code had been fixed — which is worse than never having written
it, because a plan is what someone reads before doing something
irreversible.

Sampling three 1 MiB windows cannot prove two files identical: they can
differ anywhere in the unsampled remainder, which on a 12 GB file is
essentially all of it. The contract is one-directional:

    different segmented hash  ⇒  DEFINITELY different
    same segmented hash       ⇒  CANDIDATES, nothing more

So EVERY candidate/keeper PAIR is full-hashed at the destructive
boundary — not the survivor alone, which would prove nothing about the
file being deleted. Enforced in code by `SignatureVerification`, whose
`VerifiedDuplicate` has no accessible initializer.

### What shipped, and the two traps found on the way

`FileHasher.segmentedHash` → `v1:<sha256>` over version ‖ size ‖ head ‖
middle ‖ tail. `fullHash` for verifying a survivor before deletion.
`contentHash` is a new additive field beside `partialMD5`, which is
untouched.

Two gaps surfaced while wiring it, both of which would have wasted a
night:

1. **A rescan cannot populate it.** `probeFile` consults the SQLite probe
   cache first and returns early on a hit, before any hashing. A full
   rescan of a catalogued volume would burn hours of ffprobe and produce
   zero hashes.
2. **A rescan could ERASE it.** A cache hit returned `contentHash = ""`,
   which would overwrite hashes a backfill had just computed. Fixed by
   making `content_hash` a probe-cache column with an additive
   ALTER TABLE migration — the same reason `partial_md5` has always
   survived rescans.

So there is now a dedicated **hash-only backfill**:
`VideoScanModel.runContentHashBackfill()`, with
`planContentHashBackfill()` as its dry run. Skips ffprobe entirely,
resumable, only ever writes a hash onto a record that has none.

### Running it — first thing tomorrow, ~20 minutes

Cost is flat per FILE (3 seeks + 3 MiB), not per byte, so a 12 GB master
costs the same as a 200 MB clip.

| | |
|---|---|
| Reachable records | ~8,760 of 18,142 |
| Estimate | **15–25 min**, not overnight |
| Offline | ~9,400 records need their drives mounted |

Order of operations:

1. **Click `Backup Catalog` first.** The badge was yellow at 9 days — do
   not run the first bulk-mutation pass against a stale restore point.
2. Spot-check on **CrucialX10** (50 files) and confirm hashes appear.
3. Let it run across the rest of the connected volumes.

Not yet built: a UI entry point. The pass is callable but has no button —
worth deciding whether it belongs in Catalog Options or as a step inside
the Cleanup Queue itself.

---

## Storage plan — Pegasus R4 + SanDisk PRO-G40 (2026-08-13)

Decided with Rick 2026-08-12.

**RAID-5, 12 TB usable**, HDD-populated. Not RAID-0 (one drive loses
everything) and not RAID-10 (8 TB is tight, and its advantages —
rebuild speed, second-drive tolerance — matter less when the array is
not the only copy). For large sequential video, RAID-5 writes are
typically as fast or faster than RAID-10, because a full-stripe write
computes parity once instead of writing every block twice.

**Two partitions, roles fixed:**

| Partition | Size | Role | Media tooling |
|---|---|---|---|
| Gold Archive | ~8 TB | promoted keepers only | `role = .lta` |
| Home/Misc | ~4 TB | photos, projects, personal data | **never scanned** |

The second partition is a SAFETY BOUNDARY, not tidiness: VideoScan never
scans it, never catalogs it, never offers to purge from it. Rick's
non-media data sits outside the blast radius of any media-tool bug or
mis-click — including the junk deletion still to be built.

**Tiering by how files are used**, not by size:

* **SanDisk PRO-G40 4 TB** — the working set. Cleaning, transcoding,
  combining, analysing. Scratch by definition: everything on it exists
  elsewhere, so a failure costs time, not footage. Signature and dossier
  passes want to run here — they are seek-bound and it has no seek
  penalty.
* **RAID Gold** — write-rarely, verify-often. 3-star (Gold) material.
* **LaCie** — demote to secondary once its content is on the RAID.

**A RAID is not a backup.** RAID-5 survives a dead drive; it does not
survive fire, theft, a controller scribbling the array, or deleting the
wrong folder. The preservation checklist encodes this — the RAID can
only ever tick "archived locally".

**Sequencing, and the one thing not to rush:** do not copy anything to
Gold before the junk purge and duplicate collapse. Migrating 6.8 TB when
3.0 TB of it is duplicates, junk, and photos pays for the copy twice and
pollutes a brand-new archive on day one. Clean, then promote.

**Rating scale:** use the EXISTING `starRating` (0–3), do not invent a
parallel gold/silver/bronze enum. ★★★ Gold · ★★ Silver · ★ Bronze ·
unrated. Three stars becomes the promotion trigger for the Gold
partition.

**Open:** migrating a folder that used to be a volume (Rick's question)
— Relocate currently thinks in volumes; a former-volume folder needs its
provenance carried across so the journey stays intact.

---

## P1 — Cleanup Queue (assisted junk detection → review → delete)

Rick: *"scan for likely junk, music, non-av files, etc, and then this gets
a special tag, so all I have to do is review then delete."*

### What already exists (compose, don't rebuild)

| Piece | What it gives us |
|-------|------------------|
| `MediaAnalyzer` | `junkScore` + `junkReasons[]` + suggested `mediaDisposition`, from filename/path/duration/audio/resolution signals |
| `MusicTriage` | music-library audio, with precision vetoes (MXF halves, correlated audio, video-adjacent stems) |
| `NonVideoMediaPurge` | extension × volume matrix with "(N paired)" safety annotation |
| `CoverArtMusicPurge`, `UnrelatedAudioPurge` | narrower targeted sweeps |
| `VideoScanModel+JunkDelete.deleteConfirmedJunk()` | trash-vs-permanent, reachability split, soft-delete + undo banner |
| `WorkflowTags` | the "special tag" Rick wants, already canonicalized |
| `CatalogStorageTotalsCalculator` | the same four buckets, already classified (built today) |

The classifiers exist and are individually well-tested. **What's missing is
one ranked review surface** — today they're scattered across separate
dialogs, so reviewing means opening four windows and losing the thread.

### Design

A **Cleanup Queue** window with one job: turn 3 TB of ambiguity into a
short list of batch decisions.

1. **Sweep** — one catalog-wide pass runs every classifier, writes
   `mediaDisposition = .suspectedJunk` plus a workflow tag
   (`cleanup/music`, `cleanup/nonav`, `cleanup/junk`, `cleanup/dup`) and
   the reason string. Nothing is deleted; this pass is pure labelling and
   is fully reversible.
2. **Batch** — group by (reason × confidence), not by file. Each batch row
   shows count, total GB, a thumbnail contact sheet, and three buttons:
   **Confirm all · Reject all · Review individually**.
3. **Rank** by `bytesReclaimable × confidence`. Rick sees the 400 GB
   decision before the 4 GB one — the lowest-hanging fruit first, which is
   exactly what he asked for.
4. **Confirm** flips the batch to `.confirmedJunk`. Deletion then runs
   through the **existing** `deleteConfirmedJunk` path. No new deletion
   machinery — that is where the danger lives, and it is already tested.

Reuse `TriageView`'s row idiom so it feels like the app, not a bolt-on.

---

## P2 — Duplicate clusters with safe collapse

Rick: *"hey look you got 8 copies of this file that weighs 12gb, let's
archive it and delete 5 of the 8."*

### Two tiers — they need different UX because they carry different risk

**Tier A — exact-copy CANDIDATES.** Same segment hash + size. NOT
byte-identical — that word was wrong here (codex #338); a matching
signature makes two files candidates and nothing more. Safe to
auto-PROPOSE a keep/delete split, never to auto-execute one: each pair
is full-hashed at the moment of deletion.

**Tier B — near duplicates.** Same content, different encode (a transcode,
a trimmed version, a different resolution). Byte hashing will never find
these — `PerceptualHash` (dHash64 + Hamming distance) already exists and
will. These are the ones where "8 copies" is really "3 originals and 5
re-encodes". **Never auto-delete Tier B.** Propose keep-best (highest
bitrate × resolution × duration) and require an eyeball.

### Safety invariants — every one gets a test

1. Never reduce a cluster below **N surviving copies** (N is Rick's call,
   see open questions).
2. Survivors must sit on **≥2 distinct physical volumes** — use
   `PhysicalStoreResolver`, not volume name, so two partitions of one RAID
   don't count as two.
3. **Never delete when any cluster member is on an offline volume.** You
   cannot verify what you cannot reach.
4. Never delete from a volume whose role is `.archive` / `.lta` / Gold.
5. Deletion preference order: scratch (X9/X10) → retired insurance →
   backup → never original/archive.
6. **Full-hash EVERY keeper/candidate pair immediately before** each
   deletion — not the survivor alone, which says nothing about the file
   being removed, and not at scan time, because drives change between
   scan and delete. Implemented; see `SignatureVerification.verify`.
7. First runs: soft-delete the record (`purgedAt`) and move the file to
   **Trash**, never permanent. Undo banner arms.

### Ranking (the "lowest hanging fruit" heuristic)

```
score = bytesReclaimable × confidence ÷ risk
```

where `risk` rises with: any offline member, Tier B rather than Tier A,
any master/archive-role member, and low duplicate-evidence coverage. This
surfaces "8 identical copies of a 12 GB file, all online, all on scratch
volumes" at the top — maximum reclaim, minimum doubt.

---

## P3 — Gold Archive + promotion + journey

Rick: *"once we get a very beloved file we can promote it to the master
RAID for safekeeping and the file's journey will be logged."*

Existing: `VolumeRole` already has `.archive` and `.lta`;
`ArchiveStage` already has `.masterAssigned` / `.backedUp` /
`.readyForArchive` / `.archived`; `BackupEntry` records destinations;
`FileJourneySheet` already renders a vertical timeline from
`JourneyEventKind`.

So promotion is mostly **wiring, not invention**:

- Designate the RAID's Gold partition as `role = .lta` (or add
  `.goldArchive` if Rick wants it visually distinct from existing LTA).
- **Promote** action: copy → verify segment hash at destination → set
  `archiveStage = .archived`, `masterLocation`, append a `BackupEntry`.
- Add `JourneyEventKind.promoted` (and probably `.cleaned` for the
  Combine/Repair outputs). `FileJourneySheet` renders it for free.
- Rick's target journey reads end to end:
  *recovered from internal RAID on the cheesegrater → migrated to
  MediaExpansion → cleaned to `file_cleaned` → promoted to Gold Archive.*
  `originalFullPath` + the provenance chain already carry most of this.

---

## P4 — Fix the footer's confusing totals (Rick's note tonight)

> *"I just added up all the media on all the present volumes and they don't
> total to 6.8 TB so users could be confused. We may need to say total media
> in catalog, total media online, total unique."*

He's right, and his own three-figure suggestion is the fix:

```
TOTAL MEDIA   IN CATALOG 6.8 TB   ONLINE 4.9 TB   UNIQUE 3.8 TB
```

`ONLINE` is what the visible rows actually add up to, which is the number
his eye tries to verify. Add `onlineBytes` to `CatalogStorageTotals`, using
`VolumeReachability`. **Watch out:** reachability touches the filesystem, so
it must NOT run inside the O(records) loop — read it from the existing
`VolumeStatusCache` and pass a `[volumeName: Bool]` map into the pure
calculator, keeping the calculator a pure function (its tests depend on
that).

Still unresolved and worth one line of UI honesty: the Media Size column
double-counts records migrated between volumes, so the column can exceed
even the ONLINE figure on a migrated catalog.

---

## Not yet safe to automate (codex #338, 2026-08-13)

Manual, deliberate duplicate cleanup is accepted. UNATTENDED or
automated deletion is not, for two reasons still open:

* **A narrow TOCTOU window.** The two files are hashed sequentially and
  then removed; nothing revalidates identity between the last read and
  the `removeItem`. A human clicking through a review queue is not
  meaningfully exposed; a loop deleting thousands unattended is. The fix
  is fd/inode/ctime revalidation at the boundary — hold the descriptor
  used for hashing and confirm it still refers to the same inode with an
  unchanged ctime immediately before removing.
* **Other destructive callers are unaudited.** `deleteConfirmedJunk` is
  Trash-backed and soft-delete-backed, so it is believed safer, but
  "believed" is exactly the word that failed on 2026-08-12.

## Open questions — need Rick's answer before P2 ships

1. **Minimum surviving copies?** 2 or 3 — and must one of them be on Gold?
   This single number decides how much space the collapse reclaims.
2. **Trash or permanent** for the first runs? (Trash needs free space equal
   to what you're deleting — on a full LaCie that may not exist.)
3. **"Archive to iCloud" before deleting** — flagging a tension: the profile
   says self-hosted, open standards, avoid vendor cloud lock-in. The 12 TB
   Gold partition looks like the better archive target. Worth a decision
   rather than drift.
4. **"Delete from catalog"** — soft-delete (record kept, hidden, reversible;
   already implemented) or hard record removal? Strong recommendation: soft.
   The record is the only memory that the file ever existed.

## Test posture

Feature-test checklist (CLAUDE.md) applies to all of it, with extra weight
on **isolation** and **negative tests** — this is the first feature in the
app that deletes irreplaceable family media from disk. Per
`feedback_safety_critical_testing`: every safety invariant above needs a
test that proves it *blocks* the deletion, not just that the happy path
works.
