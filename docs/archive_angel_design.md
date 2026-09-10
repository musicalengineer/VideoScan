# Archive Angel — design (2026-09-09, rev 1)

Rick's ask (9/09): an autonomous archivist that walks the catalog, finds the
videos that should be in the Master Archive but are not, prepares everything
in a buffer, and presents a reviewable batch. Two stages from the user's
point of view. "It is better to start getting videos promoted than leaving
them off RAID" — but never junk, and always reviewable.

This document is the design-before-code. Nothing here is built. Rick's
decisions so far are recorded in §9; open questions are in §10.

## 1. What it is, in one paragraph

Archive Angel (AA) is the first capability of the MediaAngel idea
(`project_media_angel_vision`): a background steward with a bounded job. It
is a **proposer**, not a decider. It scores unarchived catalog records with
transparent evidence, picks the top N, prepares the original's companions
(balanced audio, access copy, lossless preservation copy) in a buffer on
the fastest SSD, and stops. The user reviews the batch in a new
"Recommended To Be Archived" sheet — rename, deselect, note, approve — and
on **Promote** the existing Promote job copies originals and companions into
the archive with hash verification, manifest rows, and linked catalog
records, exactly as it does for a hand-picked file today. The archive-touching
code path does not change.

## 2. What already exists (reuse, do not rebuild)

| Need | Existing piece | Notes |
|---|---|---|
| Safe copy into the archive | `PromoteToArchiveJob` (+Steps), manifest, `.promote_journal.jsonl`, `.promote_decisions.jsonl` | Copy → streamed SHA-256 both sides → rename into place → manifest row → linked record. Never a move. Resumable by journal. |
| Which copy is the original | `CopyFamilyAssessor` (Promote-Helper slice 1) | Lexicographic decision: complete recording → original generation → not damaged → native geometry → sustainability. |
| Is the format at risk | `ArchiveReadiness.format` (`.archivalSafe` / `.atRisk`) | Longevity advice, audio first. |
| Audio problem detection | `AudioBalanceAnalyzer`, `AudioBalanceProbe`, Verify Audio job | Verified OK / problem / not verified. |
| Balanced audio derivative | `BalanceAudioJob`, `HelperAudioRepair` | Produces a repaired companion, never alters the original. |
| Access copy / preservation copy | `TranscodePreset.archival` / `.preservation` via Transcode job | HEVC/H.264+AAC access; FFV1+PCM preservation. |
| Junk evidence | `junkScore`, `junkReasons` (`MediaAnalyzer`), `mediaDisposition` | Machine evidence; Disposition is human-only. |
| Importance evidence | `starRating`, `confirmedByUserPeople`, `detectedPeople`, `suspectedPeople`, `sceneCaptions`, `ocrText`, `inferredRecordDate` + confidence, `embeddedCreationDate`, `userNotes`, `tags`, `tapeName`/`avidClipName` | All on `VideoRecord`. |
| Where a file lives | `VolumeRole`, `originVolume`, `archiveStage` (`.none` … `.archived`) | Unarchived = `archiveStage < .masterAssigned` and no `derivedFrom` archive child. |
| Long-running, journaled, cancellable work | MFO job window (`MediaFileOperations.Kind`) | AA becomes a new kind: `.archiveAngel`. |
| Scratch for transcodes | `RAMDisk` (`mountCombineRAMDisk` pattern) | Scratch only — see §5. |

## 3. Stage 1 — Consider

**Invocation.** Archive tab → "Archive Angel…" button (next to the Archive
Helper). Sheet asks two things: how many to consider (10 / 25 / 35 / 50) and
a time budget (default: until done; overnight option = stop at a clock time).
Requires a designated Master Archive; otherwise the same nag-button that
opens the designation sheet.

**Candidate walk.** One O(records) pass off the main actor, in the job,
never in a view body. Records are eligible when ALL hold:

- video stream present (`.videoOnly` or `.videoAndAudio`; audio-only is a
  separate later capability);
- not archived: `archiveStage < .masterAssigned`, no archive child via
  `derivedFrom`, not on the Master Archive volume;
- not excluded by the hard floor (§3.2);
- volume currently online (offline candidates are listed under "would have
  considered" but never prepared).

**3.1 Score = evidence lines, summed, every line printed.** The number only
orders the list; the lines are what the user reads. Weights are a starting
point and live in one table so they can be tuned without touching logic.

| Evidence | Points | The "why" line it prints |
|---|---|---|
| ★★★ | 100 | "You rated it best" |
| ★★ | 40 | "You rated it better" |
| Confirmed person tag(s) | 25 each, cap 75 | "Donna (confirmed), Tim (confirmed)" |
| Detected/suspected person(s) | 8 each, cap 24 | "Looks like Donna, Matt (machine)" |
| Play history (§3.3) | 0–40 | "Played 14 times, last on 2026-07-04" |
| Metadata richness (§3.4) | 0–40 | "Notes, 3 tags, captions, transcript" |
| Date known (confidence ≥ 0.8 or embedded/human date) | 20 | "Dated 1994-11-24 (OCR consensus 0.92)" |
| Date low-confidence | 5 | "Date uncertain (0.55)" |
| Duration tier — 5–15 min | 10 | "Runs 12 min 40 s — a full scene" |
| Duration tier — 15–30 min | 25 | "Runs 22 min 10 s — a long scene" |
| Duration tier — 30–60 min | 45 | "Runs 41 min 3 s — likely a whole tape or half" |
| Duration tier — 60 min and up (no ceiling) | 60 | "Runs 1 h 2 min — likely a whole tape" |
| Format at risk (`ArchiveReadiness.format == .atRisk`) | 15 | "At-risk format (MJPEG) — archive sooner" |
| Only copy (no duplicate group, single volume) | 15 | "This is the only copy" |
| On a retired/insurance/scratch volume (`VolumeRole` ≠ workspace/backup) | 10 | "Lives on MyBook (retired drive)" |
| Audio verified problem | 0 (informational) | "Audio: channel imbalance — will balance" |

**3.2 Hard floor (never a candidate, reported as rejected with the reason):**
duration < 60 s for EVERY clip, marked or not (rev 3, Rick 2026-09-10 — see
§3.4); `mediaDisposition == .confirmedJunk` or `.junk`; `junkScore`
≥ 5 with `starRating == 0`; not playable / un-probeable; a paired MXF half
(pair state computed) — the Combine result is the candidate, not the half;
duplicate of a record already archived (same `contentHash` or confirmed dup
group with an archived member). "Transitions and weird teeny bits" fall to
the duration and junk lines; the rejected list shows the count per reason so
Rick can see the floor working.

**3.4 Length is the "whole thing" signal (rev 3, Rick 2026-09-10).** "Usually
there's a longer video of the whole scene, say down the Cape, and a 60 s or
less clip is just a small edit I made to send to someone as 'Remember the
Cape in 1998'. We need to archive the originals and/or the long versions,
not these tiny segments." So: (a) the floor is a flat 60 s — a star, a
person, a note or a date no longer halves it (the 30 s marked exception let
a starred 35 s edit through, exactly the clip whose long original should be
picked instead); short clips STAY in the catalog, they are just not Angel
candidates for now; (b) duration is tiered, not a flat sweet band — a whole
DV tape is 60 min and a half tape 30, so anything that long is almost
certainly the capture, and an unrated, dated whole tape reaches grade B on
its own (60 + 20 + 5); (c) ties break longer-first after the date.
Deferred heuristics if this is not enough: a short clip whose folder or tape
name holds a much longer sibling is "an edit of X"; a name that looks like a
share-out ("for Mom", "…clip", "…edit") is demoted. Every row in the review
sheet and the chevron turndown has Show in Catalog / Show in Finder so the
short/long judgement can be made by eye.

**3.3 Play history.** The catalog has no play counter today. Two sources:

- **Spotlight** (`kMDItemUseCount`, `kMDItemLastUsedDate` via `MDItem`)
  — macOS increments these when Finder/QuickTime/VideoScan's player opens
  the file. Free, read-only, and it carries history from BEFORE VideoScan
  existed. Read at score time for candidates only (one `mdls`-equivalent
  call per file, off-main, cached in the job).
- **In-app** (proposed additive fields on `VideoRecord`: `playCount: Int`,
  `lastPlayedAt: Date?`) incremented by the catalog player and the Hallie
  web player. Additive schema → Rick's OK (§10).

Points: `min(40, 4 × log2(1 + uses))` so 1 play = 4, 7 plays = 12,
100 plays = 27; plus 5 if played in the last year.

**3.4 Metadata richness.** Count of populated human/derived fields:
`userNotes`, `tags` (≥1), `confirmedByUserPeople`, `sceneCaptions`,
`ocrText`, `inferredRecordDate`, `embeddedCreationDate`, `tapeName` or
`avidClipName`, `starRating > 0`. 5 points each, cap 40. The line lists what
is present, not the number.

**3.5 Selection.** Sort by score, tie-break oldest date first (older tape is
at more risk), take N. Then for each, run the **preparation** steps (§4).
Progress reported per candidate in the MFO row: "7 of 25 — 1993 Cape Cod:
balancing audio (2 of 4 steps)".

## 4. Preparation per candidate (all in the buffer)

Order matters: audio first, because the access copy must be made from the
fixed audio when there is one.

1. **Resolve the original.** If the record is in a copy family, run
   `CopyFamilyAssessor` and take its recommended original; note "chose
   MXF on LaCie over the MP4 on X9 — native DV, complete audio". If the
   recommendation is unconfirmed, still proceed but print the caution.
2. **Verify audio** if not already verified (`ArchiveReadiness.audio ==
   .notVerified`). Result recorded on the catalog record as today.
3. **Balanced audio** — ONLY if verify found a problem the balancer can fix.
   Output: the repaired companion in the buffer. Line: "Audio balanced
   (left −9 dB)".
4. **Access copy** — `TranscodePreset.archival`, from the balanced companion
   when one exists, else from the original. Always made (it is what the
   family plays on iPad).
5. **Lossless preservation copy** — `TranscodePreset.preservation` (FFV1 +
   PCM), ONLY when `ArchiveReadiness.format == .atRisk`. A DV, DVCPRO, HDV,
   ProRes or FFV1 original IS the preservation master; an FFV1 copy of it
   doubles archive size for nothing. Line when skipped: "Lossless copy not
   needed — DV original is the preservation master".
6. **Fallback.** Any step that fails degrades, never blocks: the candidate
   stays in the batch as "original only" with the failure line in red
   ("Access copy failed: ffmpeg exit 1 — original will still be promoted").

Each step runs through the existing job for that step (Verify Audio,
Balance Audio, Transcode) with the buffer as its output directory. Nothing
new touches ffmpeg.

## 5. The buffer

**Location:** a directory on the fastest **SSD**, not the RAM disk. Rick
9/09: "we'll try with a fast ssd" (faster Mac + SSD coming in October).
Reasons: Stage 1 can run for hours and the review can wait a day; the
buffer must survive an app quit or reboot; 25–50 candidates' companions do
not fit in RAM. The RAM disk stays what it is today — per-step transcode
scratch, mounted and ejected inside a step.

**Choice of SSD:** setting "Archive Angel buffer" in the Archive tab,
default = the internal volume (`volumeIsInternal`) under
`~/Movies/VideoScan Buffer/ArchiveAngel/`; Rick can point it at the fast
external. Free-space check before each candidate: need original size × 3
(worst case: balanced + access + lossless); below that, the run stops
cleanly with "buffer full after 18 of 25" and the 18 are reviewable.

**Layout:** one folder per batch, one per candidate inside it, plus a
single JSON plan that is the source of truth for Stage 2:

```
ArchiveAngel/
  batch-2026-09-10T02-00/
    plan.json                      ← candidates, scores, why-lines, steps, outcomes, user edits
    <recordUUID>/
      audio-balanced.<ext>
      access.mp4
      preservation.mkv
```

Originals are **not** copied into the buffer. They need no work; at Promote
time the Promote job copies source → archive with its own verification, as
it does today. Copying them twice would be wasted I/O on the largest files.

`plan.json` is journaled (rewritten atomically after every step) so a
crash mid-batch resumes where it stopped; the MFO job kind `.archiveAngel`
lists in-progress and reviewable batches.

## 6. Stage 2 — Review: "Recommended To Be Archived"

A sheet opened from the MFO row or the Archive tab when a batch is ready
(badge "25 ready to review" — nag-button pattern, the badge performs the
open). Rows, one per candidate:

- thumbnail · proposed archive name (editable) · proposed archive date
  (editable; drives the decade/year folder) · score with the why-lines
  expanded on click · companions made (chips: Original · Audio balanced ·
  Access · Lossless; grey chip with the reason when skipped) · notes field
  (appended to `userNotes`) · checkbox (default on).
- Footer: "25 recommended · 3 deselected · 41 GB to copy · 7 rejected as
  junk (show)". Buttons: **Promote 22** · Cancel (keeps the batch) ·
  Discard batch (deletes buffer files, records the decision).
- "Show" on rejected opens the hard-floor list with reasons — the way Rick
  checks the floor is not too strict.

Renames use the archive naming rule (`YYYY-MM-DD_Slug_SeqNN.ext`, unknown
parts `xx`) with `ArchiveNameAdvisor` proposing the slug from tape name,
Avid clip name, captions, or the original filename. The original filename
is preserved in the manifest and `originalFullPath` regardless.

**Promote** enqueues ONE Promote job for the batch: for each candidate, the
original (from its source volume) and each companion (from the buffer) with
`derivedFrom` → the original's archive record and `derivationKind` =
`"transcode:archival"` / `"transcode:preservation"` / `"audio-balance"`
(additive field values — Promote-Helper slice 3 already asked for this).
Companions go in the same year folder with a role suffix
(`…_access.mp4`, `…_preservation.mkv`, `…_audio-balanced.<ext>`). Manifest
rows carry the role. On success the buffer folder for that candidate is
deleted; on failure it stays and the row shows why. Final report: "22
promoted (22 originals, 21 access copies, 4 lossless, 3 balanced audio);
1 original-only: <name> — access copy failed".

## 7. Final approval and archive curation (Refile)

Rick: after a batch he inspects the archive and clicks final approval; and
the archive already holds misnamed and misdated files.

- **Final approval** = the existing `archiveFixity` + a new manifest field
  `approvedAt` set by an "Approve" gesture in the Archive tab (per file or
  per batch). Unapproved archive files show a hollow badge; Hallie can
  answer "what's waiting for approval". Approval is a human-only tier, like
  Disposition.
- **Refile** (parked in `project_master_archive_promotion_design`, now
  needed first): rename, redate, and move-within-tree for a file already in
  the archive, in one atomic gesture: rename on disk → move to the correct
  decade/year folder → manifest row updated (old path retained as
  `previousPaths`) → catalog record updated (`fullPath`, `originalFullPath`
  untouched). Companions move with their original. Fixity is re-checked
  after the move (same bytes, new path). Surface: Archive tab row → "Rename
  / Redate…", and multi-select "Redate to…".
- **Undo / ignore** after promotion: copy-not-move means the source is
  untouched; "Remove from archive" deletes the archive copy and companions,
  writes a retraction row to the manifest, and resets `archiveStage` — a
  separate human gesture with its own confirmation.

Refile ships **before** AA runs at batch size 50, because every batch adds
files under the same naming and dating rules.

## 8. Slices (each independently useful, each with the 5-dimension tests)

| # | Slice | Schema | Ships |
|---|---|---|---|
| 0 | **Refile** (rename / redate / move within the archive) + `approvedAt` | manifest fields (additive) | first |
| 1 | `ArchiveAngelScorer` — pure core: eligibility, hard floor, evidence lines, selection. Table-tested; 100k-record scale test with a time budget | none | second |
| 2 | Play history: Spotlight reader (cached, off-main) + in-app `playCount`/`lastPlayedAt` | additive `VideoRecord` fields — Rick's OK | with 1 |
| 3 | `.archiveAngel` MFO job: candidate walk → preparation pipeline in the buffer, `plan.json` journal, resume, free-space stop | none | third |
| 4 | Review sheet + batch Promote (companion roles, `derivationKind` values) + final report | `derivationKind` values, manifest `role` (additive) | fourth |
| 5 | Approve badge + Hallie "waiting for approval" answer; overnight schedule (time-budget stop) | none | fifth |

Slice 1 alone already answers "what would the Angel pick?" as a dry run
list in the Archive tab, which is the cheapest way to tune the weights on
Rick's real catalog before any file is transcoded.

## 9. Decisions recorded

- 9/09 Rick: buffer on the **fastest SSD**, not RAM. (October: faster Mac + SSD.)
- 9/09 Rick: play history and metadata richness are candidate signals.
- 9/09 Rick: originals + fixed audio + access + lossless "when possible";
  original-only fallback acceptable if noted.
- 9/09 Rick: batch sizes 10 / 25 / 35 / 50; review before any archive write;
  final approval after inspection; Refile needed for existing misnamed/misdated files.
- Standing rules applied: copy-not-move; machines write evidence, humans decide;
  Disposition and approval human-only; no O(records) work in view bodies;
  additive schema only, with Rick's OK.

## 10. Open questions (one at a time)

1. **Lossless companion for native-format originals?** This design makes it
   conditional (at-risk formats only). If Rick wants FFV1 for every video,
   §4 step 5 loses its condition and the buffer sizing in §5 doubles.
2. In-app `playCount` / `lastPlayedAt` on `VideoRecord` — additive fields, OK?
3. `derivationKind` string values and a manifest `role` column — additive, OK?

## 12. RAM scratch tier (Rick 2026-09-09 17:20, for the M5 Ultra / 96 GB Mac Studio)

Rick: a performance option allocating 8 / 16 / 32 GB of RAM to Archive Angel
as a fast conversion buffer, SSD for whatever won't fit; "any glitch that
stops the RAM cache would also stop the AA anyway, so make it as fast as
possible." Codex (#1252): keep the durable batch on SSD; RAM only for
recomputable per-step scratch; at most one bounded in-flight output; persist
and verify to SSD before a step is "done".

Both are right, and they meet at the **read side**, which is where the time
actually goes:

- **Encoding is not disk-bound.** HEVC via VideoToolbox writes 10–50 MB/s;
  FFV1 is CPU-bound (24 slices — the Ultra's cores matter, not the disk).
  Writing outputs to RAM instead of the internal SSD gains little.
- **Reading is.** A DV hour is ~13 GB and the Angel reads the ORIGINAL up to
  four times (verify, balance, access, lossless) from a RAID or a LaCie at
  150–300 MB/s: 3–6 min of I/O per file, repeated per pass. Read it ONCE into
  RAM and every pass runs at memory speed. The app already has this seam:
  `RAMDisk` (ref-counted `mount(sizeMB:)`, `memoryFloorGB`) and
  `probeFile(prefetchToRAM:ramPath:)`.

**Design:**
- Setting "Archive Angel scratch RAM": Off / 8 / 16 / 32 GB (default Off on
  64 GB machines, 16 GB when `hw.memsize` ≥ 96 GB). Lives with the other
  performance settings; respects `memoryFloorGB`.
- Per entry, if the source fits in (budget − in-flight outputs − 1 GB
  headroom) AND its volume is not the internal SSD: copy the original to the
  RAM disk once (`ArchiveAngelPlan.Entry.scratchPath`), verify size, and run
  every step from the RAM copy via an input-override seam on Transcode /
  Balance (they take a record; add `inputURLOverride`). Outputs go to the SSD
  entry dir as today. When the entry is `.ready`, remove the RAM copy.
- Oversized or unknown-size sources stay on SSD/source; RAM-full mid-entry
  → retry the step from the original (recomputable); memory-pressure
  warning → drain and fall back to SSD for the rest of the batch; RAM disk
  is ejected at job end, never left mounted.
- Nothing durable ever lives in RAM: plan.json, review edits and completed
  companions are SSD-only, so a crash costs at most one in-flight step.

**Measured gain to justify it (codex's question):** on this M4 with the
LaCie, time one 1-hour DV entry with all four steps from the source volume
vs from a RAM copy. Expected: 4× reads → 1× reads, i.e. minutes per file on
spinning storage, near zero when the source is already on the internal SSD.
Ship only if the measurement shows ≥ 25 % end-to-end on RAID sources.

**Slice:** after Refile and the interaction gate; GH issue tracks it.
