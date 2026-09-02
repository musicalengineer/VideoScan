# "Ready to archive" — an indicator that helps the user keep promoting (design, 2026-09-01)

Rick, 2026-09-01 evening: "we need an indicator maybe when a file is ready
for archive, ie, audio verified, date set, analyzed, flagged important or
has people … a lot of those need audio verify. I also think some of the
audio requirements might be higher than they need to be, for example, if a
video has audio that is mono, why balance and make it stereo … The goal is
just to assist the user to keep promoting files to the archive."

## What exists today (read before designing)

- `ArchiveReadiness` (2026-08-16): per-file assessment from catalog fields —
  playable, audio (verifiedOK / verifiedProblem / notVerified / none),
  format risk, date state; warnings audio-first; blocks ONLY an
  un-probeable file. Used by the Archive Helper and Assess Copies.
- `ArchiveNudge` (2026-08-21): "It looks like N files are ready" under the
  Archive progress bar. READY = not archived, not an extra copy, vouched
  (Important / stars / stage Ready or Master), not junk, dated to the year.
  NEAR-READY = same but undated. Audio verification is NOT a criterion
  there; the Helper checks it at promotion time.
- Verify Audio: `VerifyAudioRules.isDamage` says channel imbalance, mono,
  silence, no-audio and surround are NOT damage — status stays "ok".

## Finding 0 — mono is being called a problem, and it is a bug, not a policy

`ArchiveReadiness.assess` (ArchiveReadiness.swift:135):

    audio = i.audioVerifyNote.isEmpty ? .verifiedOK : .verifiedProblem(i.audioVerifyNote)

Verify Audio persists status "ok" with note "mono audio" for a healthy
single-channel track (VerifyAudioProbe.swift:288, `isDamage` false). The
readiness code then reads the non-empty note as a PROBLEM, so the Helper
says "Audio problem — mono audio" and the file looks unready. The same
happens for "one-sided audio", "silent audio" and "surround audio".

Rick's instinct is right and the archive principle already agrees:
PRESERVE – ASSESS – RECORD, never alter bytes. A mono original is a
faithful original. Balance Audio (mono → dual-mono stereo) is an ACCESS
convenience, never an archival requirement, and promotion does not run it
(checked: PromoteToArchiveJob+Steps copies and verifies; it never
transcodes audio).

Fix: readiness derives `verifiedProblem` from the persisted STATUS
("damaged"), and carries the note as an informational line ("mono audio —
fine as is") rather than a warning. One line of logic, a table test per
note, and the Helper stops nagging about mono.

## The indicator

One idea, three places, one source of truth.

### The source of truth: `ArchiveCandidacy`

A small pure value computed per record (nonisolated, table-testable,
memoized like `VolumeStatusCache` — never O(records) in a view body):

| check | satisfied when | one-click fix (nag-button pattern) |
|---|---|---|
| **Vouched** | Important, 2–3 stars, stage Ready/Master, or any person tagged (Rick's "has people") | Mark Important |
| **Dated** | date known at least to the year (same resolver as placement) | Set date… (opens the date entry) |
| **Audio verified** | verify status "ok" or "damaged-and-acknowledged", or no audio track | Verify Audio |
| **Not an extra copy** | dup keeper or unscored; not junk | Assess Copies |

`Archived` is a fifth, terminal state (already true → shows the archive
name, no dots).

### Where it shows

1. **Catalog table — a "Ready" column** (after Date). A 4-dot meter, the
   family reader's language, no jargon:

       ●●●●  Ready              green pill
       ●●●○  Verify audio       amber; the missing dot is the label
       ●●○○  Date, audio        amber
       ●○○○  —                  grey (only the filter surfaces these)
       ▣     Archived            quiet blue, the archive's short name

   Hover = the four lines with ✓ / ○ and the fix button for each ○.
   Click the pill = performs the FIRST missing fix (badge performs the
   fix, per the nag-button pattern). Sorting the column groups the
   ready files at the top.

2. **Showing box — a "Ready to archive" chip** beside the existing
   Show filters, plus "One step away". The catalog becomes the to-do
   list Rick asked for on 8/22.

3. **Archive window — batch buttons on the nudge.** The nudge already
   lists candidates with "why it looks ready". Add the same 4-dot meter
   per row, and above the list one button per missing step with a count:
   "Verify audio for 23 files", "Set dates for 6". Verify Audio is already
   a batch MFO job; wiring the button = building the record list.

### What it is not

- Not a gate. Readiness never blocks Promote; the Helper keeps its
  override. The indicator invites; it does not police.
- Not a new persisted field. Everything is derived from what the catalog
  already stores, so nothing can go stale and #167-style clobbers cannot
  eat it.
- No new audio requirement. "Verified" means Verify Audio has looked, not
  that the audio is stereo, balanced, or transcoded.

## Scale and tests (feature-test checklist)

Logic: candidacy table tests (each check, each fix label).
Scale: 100k synthetic records, candidacy for all in < 100 ms, memoized;
the column must not recompute on scroll (sensor).
Media matrix: not needed — no media is opened.
Isolation: none — no global state.
Sensor: the Helper's warning list for a mono file contains no "problem".

Estimate: one focused day. Finding 0 is an hour and can go first.
