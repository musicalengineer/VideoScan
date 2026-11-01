# Audit Archive — an overnight health check of the Master Archive

**Status:** PROPOSED 2026-10-15 (Rick + Claude). No code yet. Reuses Archive ▸ Verify
(fixity), Check Media (ffprobe + the audio diagnosis), the Fingerprint Sound stamps (decode
outcome, audible seconds), and the one Repair door (`repair_center_one_door`). Serves goal 1
(preserve) and goal 5 (repair) in `docs/project_goals.md`.

## 1. In Rick's words

"What if we have a Verify Archive that I can kick off at bed time and let it run overnight …
verifies the catalog is robust and correct, every file pointed to exists and has audible
audio, can be played, video can be verified … in the past I had files that I kept for many
years on a computer, then one day I clicked play and got zilch: the OS was updated and the
codec was obsoleted … Doing this manually by playing every file in the archive with a human
sitting in front of every frame, verifying audio sounds good, well, that's a lot to ask."
"If it is intense we can do it by decade or subsections."

## 2. Principle: audit, never fix

The job reads; it moves, rewrites and transcodes nothing. Every finding is a flag in words
on the record, with the door that fixes it (Repair, Update…, or Promote a better transfer).
The archive stays read-only to background jobs (Rick 2026-09-27).

## 2a. Tier 0 — Audit Catalog: every row points at a real file (Rick, 2026-10-15 evening)

The staging copy of a VHS capture vanished from Projects on October 4 — outside the app, no
receipt, no ledger line — and for eleven days its catalog row posed as a live copy: the
duplicates job held its twin ("could not read the keeper", correctly), and Compare Media's
band said "byte for byte" from the stored hashes while the tiers could not read the file.
Rick: "if by some weird turn of events … someone moved the file or deleted the file, the
catalog has no knowledge … run an audit overnight or periodically or prior to doing a backup
catalog … ensure the catalog entries all have links to real media."

So the first tier is cheap and catalog-wide, not archive-only:
- **What:** stat every live row on every mounted volume (device + inode + size against the
  record's identity stamp where one exists). ~10,000 stats, seconds.
- **Outcome per row:** present · present but changed (size or identity differ: "replaced
  since cataloged") · gone → the existing removal marker `.missing` through the one engine,
  with the audit as the reason; a row whose drive is not mounted is "not asked", never
  marked.
- **When:** every night before the metrics publish; before any catalog backup / export;
  from Catalog ▸ Audit Catalog… on demand. One START / OUTCOME pair; the OUTCOME names the
  counts and the folders where files went missing ("3 gone under Projects/_staging_…").
- **Why it is separate from Rescan:** Rescan asks one volume when you ask; the audit is a
  standing guarantee over the whole catalog and marks nothing but presence.
- **Build first:** it is the smallest piece of this design and it closes the hole that was
  open for eleven days. Compare Media now refuses a verdict for a file that is not on disk
  (RelatedLadder.notOnDisk) — the audit is what keeps that case rare.

## 2b. What to do with the holes — Fix Links (Rick, 2026-10-15 evening)

"So we run an audit and it reports 115 files are no longer where we said … what to do? …
rescan sounds expensive and may reingest stuff we don't want, but we could search for the
missing or moved files and, after reporting the changes or missing links, have at-the-ready
a fix-links with a review."

1. **Group by folder.** One line per vanished folder ("38 gone under Projects/_staging_…"),
   because a folder move or a cleaned staging area is the common cause.
2. **Search before asking, cheapest first, no media read:**
   a. another live catalog row with the same whole-file SHA-256 and size (the file was moved
      and its new place was already scanned) — proven already;
   b. the same file name and size on any mounted drive through Spotlight (`NSMetadataQuery`
      on name + size; instant) — a candidate, confirmed by a full hash before it is called
      the same file;
   c. the vanished folder's name elsewhere on the same drive (the moved-folder case) —
      candidates per file as in b.
3. **Fix Links — one review sheet:** old path · found at · how proven (same SHA-256 /
   name + size, hashed now / not found) · choice per row and per folder: **Relink** (the
   row points at the new path and keeps its hand marks: stars, people, dates, notes;
   when the file was found as a second row the two MERGE — hand marks to the survivor, the
   old row marked "moved, now at …", never deleted) · **Mark missing** (the removal marker
   `.missing`, reason "audit"; visible under Show Removed; relinkable later when a drive
   comes back) · **Leave**. Applied through the one marker engine with a receipt.
4. **Never rescan to fix a hole.** Rescan ingests; Fix Links moves pointers. Nothing enters
   the catalog from the audit.

Outcomes: relinked · merged · marked missing · left · could not prove (a name + size
candidate whose hash differs: shown, never relinked).

## 3. The job: Archive ▸ Audit Archive…

An MFO job (chip AUDIT), overnight, resumable, scoped to the whole archive or one decade.
Confirm sheet: files to audit, bytes to read, time at the archive drive's rate, what will be
skipped (audited since its bytes last changed). Pause / Stop as every MFO job. START /
progress / OUTCOME through the one sink. Finished row: "N audited · M flagged (k audio,
j video, i codec risk, h missing) · X skipped as current".

### The checks, cheapest first, each with its own stamp

| # | Check | How | Reused from | Flag words |
|---|---|---|---|---|
| 1 | present | the file is at its path, device + inode + size as recorded | FileIdentityStamp | "not at its path" / "replaced since promotion" |
| 2 | fixity | whole-file SHA-256 equals archiveFixity | Archive ▸ Verify | "bytes changed since promotion" |
| 3 | facts | ffprobe streams match the record (duration, codecs, frame size) | Check Media | "the file's streams no longer match the catalog" |
| 4 | decodes | ffmpeg decodes video AND audio to the last frame (`-f null`), errors and early EOF counted | new; the fingerprint decoder's ProcessRunner shape | "video stops at 12:40 of 38:00" / "audio stream can't be decoded" |
| 5 | audio heard | audible seconds / duration from the fingerprint's audible map | Fingerprint Sound stamp | "no sound" / "silent after 2:10" |
| 6 | audio quality | from the same decode: clipping ratio, spectral flatness (noise), 50/60 Hz hum, DC offset, channel imbalance | the audio diagnosis + a small new analyzer | "mostly noise" / "clipped" / "hum" / "one channel dead" |
| 7 | codec risk | video/audio codec against the list of formats Apple has dropped or deprecated (Sorenson Video, Cinepak, Indeo, Animation/RLE, Graphics, QDesign, MACE, IMA4 in old containers, Apple Intermediate…) and containers that need QuickTime 7 | new table, versioned | "codec Apple no longer plays — make a preservation copy (FFV1 / ProRes)" |
| 8 | transcript sanity | audible sound but an empty or gibberish transcript (low dictionary ratio) | audioTranscript | "the transcript doesn't match the sound — re-transcribe or listen" |
| 9 | thumbnails | a preview frame exists and is not black | preview cache | "no usable preview" |

Checks 4–6 are one decode per file, shared. A file is skipped when its identity and the
checks' version match its last audit stamp.

### The stamp

`VideoRecord.archiveAudit: ArchiveAuditStamp?` — auditedAt, checksVersion, identity, outcome
(.healthy / .flagged([Finding]) / .couldNotAudit(reason)), each Finding = check, words,
severity (needs a fix / worth a look / note). The Archive tab shows per-decade counts and a
"Flagged" list; the inspector shows the findings with their doors.

## 4. Cost

Rick's archive 10/15: 653 files / 3.2 TB. One full read at the Pegasus's rate (≈ 400–600 MB/s)
is 1.5–2.5 h; incremental after that. RAM: the decode is streamed (`-f null`), the audio
analyzer works per block; the job keeps the fingerprint job's 1.5 GB / 4-decode budget.

## 5. What it is not

- Not a repair: Repair stays the one door; the audit hands it the file and the finding.
- Not a promotion gate: Promote keeps its own vetting; the audit catches what slipped
  through and what the years do to a format.
- Not a judgement of content: a boring minute is not a finding.

## 6. Tests (five dimensions)

Logic: each check against synthetic good / bad inputs (truncated file, dead audio stream,
noise, clipped, hum, obsolete codec, gibberish transcript). Scale: 100k stamps, skip logic
O(1) per record. Media matrix: mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, avi/dv, plus one
Cinepak and one Sorenson fixture. Isolation: never touches a non-archive path; a test host
audits only fixtures. Sensor: nothing in the audit writes under the archive root (the
one-writer rule), the view body does no O(records) work.

## 7. Order

After the Event Analyzer's engines (RelatedScore, EventRecommendation). The codec-risk table
and the decode-to-end check are the two pieces that do not exist anywhere yet and carry the
"clicked play, got zilch" value; build those first, then fold the reused checks in.
