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

## P0 — Full-content hashing (blocker for everything else)

**`FileHasher` today implements only `partialMD5` — a 64 KB head hash.**
That is fine for the footer's estimate and for *suggesting* duplicates. It
is NOT sufficient to authorize deleting a family video, and everything
below depends on fixing it first.

Failure mode: two distinct Avid MXF essence files from the same session
share a wrapper header and can be padded to the same length. Head hash +
size says "identical". Delete the wrong one and the footage is gone.

Proposal — **segmented hash**, not full-file:

```
segmentHash = SHA256( head 1MB ‖ middle 1MB ‖ tail 1MB ‖ sizeBytes )
```

Three seeks instead of streaming 12 GB. On a 12 GB file that's
milliseconds versus ~2 minutes, and collision risk for *real* media is
negligible — the tail segment alone defeats the padded-MXF case. Full-file
hashing stays available as an explicit "verify before delete" step on the
surviving copy only.

- New: `FileHasher.segmentHash(path:)`, persisted on `VideoRecord`
  (new field, additive — no schema migration issues).
- Backfill job over the catalog, resumable, volume-gated (reuse
  `MediaVolumeGate`).
- Tests: identical-content/different-name, same-head-different-tail,
  same-head-and-size-different-middle (the padded-MXF case), files
  smaller than 3 MB (segments overlap — must still be correct).

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

**Tier A — exact copies.** Same segment hash + size. Byte-identical.
Safe to auto-propose a keep/delete split.

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
6. **Verify the survivor's hash immediately before** deleting the others.
   Not at scan time — at delete time. Drives fail between the two.
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
