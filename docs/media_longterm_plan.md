# Media Long-Term Plan

*The strategy behind VideoScan. This is not a feature spec — it is the vision that
every feature should serve.*

## The problem

Rick has decades of accumulated media — shot on camcorders, imported to Avid, re-saved
to FCP, copied across half a dozen drives, duplicated, orphaned, partially
transcoded, partially lost. Interleaved with that is **junk**: Avid test media, FCP
scratch renders, 2-second clips that never got deleted, corrupt files, system
artifacts. The junk is likely hundreds of GB.

This didn't happen through negligence. It happened because Rick was raising four
boys and working full time, and the media accumulated faster than anyone could
triage it. That context matters because the solution can't assume infinite manual
labor — the app has to do the heavy lifting.

## The end-state vision

> "Find all media on these volumes that is important because it has family, make
> sure we have: (1) a Designated Master, (2) Backed up locally and/or cloud,
> (3) Ready for Long-Term Archive, (4) Archived to LTA done. Then we can format a
> volume (delete all junk) and recycle the old MacPro or give it away."
>
> — Rick, 2026-04-23

The magic-wand version of that sentence is what the app exists to answer. Every
feature either contributes to identifying family media, advancing its lifecycle
status, or clearing the junk that surrounds it.

## The four dispositions of important media

Each file that qualifies as "important family media" passes through four states.
The app's job is to track which state each file is in and surface the next action.

### 1. Master

There is a single, authoritative copy on a reliable, currently-maintained drive.
The Master is the one we protect, the one we back up, the one we eventually archive.
Other copies are duplicates — useful for redundancy, not load-bearing.

Criteria:
- Lives on a drive we are not planning to retire
- Plays cleanly (audio + video, no corruption)
- Has been through metadata extraction (we know what it is)
- Is not a reduced-quality re-render of a higher-quality original that also exists
- If it is an Avid audio-only or video-only track, it has been Combined with its mate
  or the pair has been promoted together

### 2. Backed Up

At least one additional verified copy exists on a volume that is *not* the same
physical machine as the Master. Sub-types:

- **Local backup** — external drive, NAS, another machine in the house
- **Cloud backup** — iCloud, Backblaze, S3, etc. — format must be open enough that
  Rick (or his sons) can retrieve it without the app
- **Off-site backup** — physically stored at a location other than home

Criteria:
- Byte-identical (or cryptographically verified equivalent) to the Master
- On a drive not listed as the Master's host
- Has been compared by Compare & Rescue and confirmed "safe"
- Number of independent backup copies is tracked (1, 2, 3-2-1-rule)

### 3. Ready for Long-Term Archive

The file is stable, will not be edited further, is a confirmed keeper, and is a
candidate for dedicated archive storage (M-DISC, offsite cold storage, cloud
cold-tier, or a ZFS pool with bitrot protection).

Criteria:
- Master + at least one verified backup exist
- Format is long-term portable (no proprietary wrappers we can't open in 20 years)
- Metadata is baked in (sidecar JSON, EXIF, or embedded tags — not just database
  entries that would be lost if the app died)
- Rick has flagged it as "worth keeping for decades"

### 4. Archived

The file has been written to long-term archive storage and the write has been
verified.

Criteria:
- LTA media (disc, cold storage, etc.) contains the file
- Verification (checksum, sample playback) has been performed and recorded
- The LTA location is documented in the catalog (which disc, which ZFS pool, which
  cloud bucket)

Once archived, the original Master + backup copies are free to be moved, compressed,
or relocated — the archive is the permanent record.

## The inverse — Junk

Everything that does not pass the "important family media" test is a candidate for
deletion. But deletion is asymmetric: restoring is hard, deleting is permanent,
so the junk disposition is gated.

Three states:

1. **None** — not yet evaluated
2. **Suspected junk** — matches heuristics (Avid test media paths, duration under 3s,
   ffprobe failure, known scratch-render naming patterns, etc.). Needs human
   confirmation.
3. **Confirmed junk** — Rick has reviewed and marked for deletion

Deletion is further gated on the important-media side:
- **A file can only be deleted if it is not anyone's Master, not anyone's sole
  backup, and has no family-member face match above threshold.**
- If Compare & Rescue shows even one other volume still relies on this file as a
  backup, deletion is blocked until that volume's Master is itself backed up
  elsewhere.

See `memory/project_junk_label_plan.md` for the implementation sketch.

## How Compare & Rescue serves the plan

Compare & Rescue is not the plan — it is one of the tools the plan uses. It answers
two specific questions that the lifecycle needs:

- **Audit mode:** "For this set of source volumes, which files exist nowhere
  outside the source set?" — drives the **Backed Up** disposition (if a file exists
  on source volumes only, it isn't yet backed up).
- **Rescue mode (1 source + 1 dest):** "Pull files from the source that are missing
  on the dest." — used to physically create a backup copy during migration (e.g.
  MacPro → new 4TB SSD).

Compare & Rescue's multi-source grid is the feature that makes the same-machine
duplicate trap go away — see `memory/project_volume_compare_multi.md` for the
MacPro case.

## End-state workflow

Once the lifecycle tracking is in place, the cleanup-and-retire sequence becomes
mechanical rather than heroic:

1. **Scan + Catalog** every volume. Every file gets a record with metadata,
   duration, checksum.
2. **Identify important media.** Face match (PersonFinder) and manual review surface
   the keepers. Family-match = highest-priority keeper.
3. **Designate a Master** for each keeper. Prefer the highest-quality copy on the
   newest drive.
4. **Verify backup copies.** Run Compare & Rescue in audit mode; flag files whose
   Master has no off-machine backup; run rescue to create one.
5. **Mark suspected junk** via heuristics. Review the candidates.
6. **Confirm junk.** Delete confirmed junk only on volumes where the important
   media is fully backed up elsewhere (gating rule above).
7. **Advance keepers to LTA status.** Bake in metadata, write to archive media.
8. **Once a volume is confirmed "no important media here that isn't backed up
   elsewhere," format it.** The app should be able to answer this question with a
   single query.
9. **Retire the old hardware.** The MacPro (or whichever old machine) can be wiped
   and recycled once the app confirms nothing is load-bearing on it.

## What this means for the app

- Every file record eventually needs at least four status fields in addition to
  the metadata it already has:
  - `masterDisposition` — is this file THE Master for its content?
  - `backupStatus` — how many independent backups, and where?
  - `archiveReadiness` — is it a candidate for LTA?
  - `archiveStatus` — has it been written to LTA?
  - `junkDisposition` — the inverse (none / suspected / confirmed)
- The UI should let Rick answer "what is the status of this file?" and "what is the
  status of this entire volume?" at a glance
- Features already shipped (catalog, Compare & Rescue, PersonFinder, Combine) are
  all subordinate to this plan. They are the verbs; the dispositions above are the
  nouns that tell Rick what work remains.

## Why this discipline matters even for a home-video app

The media we are protecting is irreplaceable. The children in these videos are
grown adults. The parents and grandparents in them may no longer be alive. A
single careless `rm -rf` on the wrong volume erases them permanently. The lifecycle
discipline above is what makes that disaster impossible by construction — you cannot
delete a file whose status doesn't permit deletion, because the app will not let
you.

That's the plan. Everything else is implementation.
