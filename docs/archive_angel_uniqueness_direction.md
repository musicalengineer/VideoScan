# Archive Angel — uniqueness and "drain the catalog" direction (Rick, 2026-09-11)

Rick, the morning after T10, on what the picker is FOR:

> "The picker should try to get the most original, usually long, not little clips … uniqueness is also something to consider — imagine I have a video, only one of someone's birthday, that would be important; on the flip side there are many dups … we need to somehow pick the best format or most original — most likely if the codec is old, it is more original; we need to transcode a copy for archive, keep the original, create an access copy … once we have all this in the archive, maybe we should delete N copies out of N+1 and indicate it is in the archive; the user can view the catalog with a filter to show only unarchived files … The overall goal: get the user to promote media that is important family memories as much as possible, **draining the catalog into the archive over time.** … The goal is to populate the archive, fill out the timeline with UNIQUE videos — not the same ones over and over or clips from the same ones. If possible compare content overnight in the background and decide what is truly unique … maybe a uniqueness score in the picker."

## What this changes about the Angel

1. **The picker chooses among a group, not just per record.** Authorized 2026-09-11: the pick path (`selectFromEvidence`) and the two candidate producers may carry Angel rules. Landed as H2 (one member per duplicate group, most-original member wins) and H3 (a derivative export yields to its related, eligible original). See `docs/archive_angel_design.md` §3.
2. **"Most original" has an order.** Codec era first (dvvideo → mjpeg → mpeg2video/hdv → prores/ffv1 → svq3 → h264/hevc/mpeg4/vp9 → unknown), then older date, longer, larger. The Angel makes the access copy and, when asked, the lossless copy — the original is what gets promoted.
3. **Uniqueness is the next signal, not a floor.** A record whose content exists nowhere else in the catalog (no duplicate group, no derivative family, no near-duplicate by fingerprint) is worth MORE, not less — "the only video of someone's birthday". Proposed: a `uniqueness` evidence line with points, computed overnight by a background comparison (segment content hash today; perceptual/scene fingerprint later) and stored in the assessment sidecar like every other machine line. Never a rejection.
4. **After promotion, the catalog should shrink.** Once an asset is byte-verified in the archive, its N surplus copies become candidates for the delete-safety path (full-verify gated, already built 8/12), the record shows "in archive", and the catalog's default view can hide archived assets ("show only unarchived"). This is the Archive Helper / cleanup side, not the Angel — but the Angel's `archivedAt` and duplicate-group facts are what make it safe.
5. **Timeline = unique videos.** The Archive Timeline should list one entry per unique content, with clips and derivatives folded under their original.

## Not decided yet (Rick)
- How aggressive the post-archive duplicate deletion should be (auto-propose vs. auto-delete after N days).
- Whether the "unarchived only" catalog view becomes the default.
- Fingerprint method for "truly unique" (segment hash is exact-content only; edits of the same tape need a perceptual/scene comparison — a T-theme for a night).
