# Archive Angel — what should it recommend? (problem statement)

*Written 2026-09-24 for a hard-problem-solving session (Fable 5.1). Status: PROBLEM, not design. Rick decides.*

## The goal behind it

Get the family's media into the Master Archive (FamilyArchive), correctly, at a pace a
person can sustain. Near-term target: **10% of media archived by 2026-10-15**. Judge
Angel by **files decided per session**, not by how clever the scores are.

Today: 90 archived / 128 verified (2.5 TB of 3.5 TB) in the master; 8,722 records
"Not Yet Archived", 5,698 of them "Needs a Date". Angel's last assessment: 60 ready,
20 need a date, 111 candidates in the list.

## What went wrong on 2026-09-24

The list was redesigned for seniors (big rows: Play · Show in Catalog · Show in
Finder · Promote/Prepare to Archive · Archive Readiness). The first real screen showed
**10 of 10 rows "Needs audio checked"**, every button "Prepare to Archive", while the
header said "60 ready". Cause: almost no file in the catalog has ever been through
Verify Audio, and the new status words treated "never checked" as a need.

Rick's reaction, in his words:

> "the candidate list should be files that are ready or near ready, something seems
> funny if they all have the same unready problem."
>
> "if we already know we recommend 20 files and they all need audio balancing, can we
> do that for the user or are we going to make him do it?"
>
> "If we're not supposed to mess with original material then maybe we're not supposed
> to balance audio, so maybe in that case, we suggest 10 files, say we recommend this
> original and original_balanced."
>
> "this is why I wanted to have an intelligent alg that could say 'oh this is a clip
> from this' or 'there are 12 copies of this material, but not one is in the archive'."

## The continuum Rick named

- **Too few:** 0 recommendations means Angel isn't working hard enough to find
  candidates.
- **Too many / all the same:** 20 recommendations that all share one unready problem
  means the list is pushing work onto the user that the machine could do.
- **Right:** files that are ready, or *near* ready. "Near ready" means a quick human
  touch: add a date, rename, sanity-check the length, decide whether it's derivative
  content.

## Principles already ruled (don't re-litigate)

- **Originals are sacred.** Promote the original as-is; improvements are *separate
  derivative files* (e.g. `_balanced`), never edits of the original.
  - Prepare already works this way: verify audio, then Balance Audio makes a separate
    balanced file only when `BalanceAudioFix.refusalReason` says the track is fixable.
    `ArchiveAngelAudioOutcome` names the outcomes: balanced / fixable / refused
    (non-damage finding) / damaged / no audio.
- **Version roles** already exist in `ArchiveItemVersions`: original · preservation ·
  access · editable · restored (balanced/cleaned/denoise) · trimmed · converted ·
  other. An archived item is a *card* of versions.
- **Short clips are edits; archive the long original.** Angel's floor is 2 minutes;
  long tapes come first, ranked by hours.
- **Most-original wins** among copies (uniqueness / drain-the-catalog direction).
- **Delete-safety:** prove the surviving copy at delete time; FamilyArchive is near
  read-only; the Trash beats permanent deletion.
- **Users think in words, not scores.** The UI shows "Ready to archive" / "Needs …",
  and the score lives only in the Archive Readiness explainer.
- **The computer melts silicon, not the user.** Derive what can be derived; ask only
  when something is ambiguous or missing.
- **Robust + logged first, then fast. Incremental beats perfect.**

## What exists to build on

- **Recommend:** `ArchiveAngelScorer` (rules v11, policy-as-data), classes
  `.ready / .needsDate / .worthALook / .anotherCopy / .notNow`, attention memory
  (fatigue, rest, fresh slots), family grouping, `ArchiveReadiness.assess`.
- **Prepare** (an MFO job): verify fixity, verify audio → balance when fixable,
  stage the batch. **Review** sheet, then **Promote** (identity checks, fixity,
  FamilyArchive gates).
- **Find Similar Footage** (Phase 1, merged 9/23): same-footage groups (3,169),
  "Identical" only on current whole-file digests, otherwise "Likely".
- **Duplicate groups + keeper policy**, **archive-copy ↔ source links**, and **fact
  lending** between fresh endpoints (dates, places, backup answers).
- **Verify Audio / Verify Video / Balance Audio** jobs, all MFO jobs.
- **Absurd-bitrate encodes** (HandBrake 90,000 fps, e.g. a 43 GB 36 s file): known,
  no rule yet.

## The hard questions

1. **When does the machine do the work instead of the user?** Should audio
   verification (and a bitrate/sanity check, and maybe Verify Video) run
   *proactively* in the background on candidates **before** they're shown? That would
   put near-ready work in the list instead of never-checked work. What does it cost
   (disk wakeups, time on 100k records, the M4 during Rick's hours), and how is it
   paced (per-disk gate, overnight)?
2. **What is the unit of recommendation: a file, or a *material* (footage)?** "12
   copies of this material, none archived" is a material-level fact. Should Angel
   recommend *materials* ("this tape exists as X, Y and a clip Z"), then pick the
   most-original member to promote and the derivatives to attach as versions?
3. **Derivatives:** is "promote original + original_balanced" one recommendation (a
   card), with the balanced version produced automatically during Prepare? When is
   mono actually correct and not "unbalanced" (source type, era, camera)? Who decides,
   and how is that remembered?
4. **Clip-of detection:** "this is a clip from that." Duration + name windows + date +
   sampled hashes exist; true containment (a clip inside a longer original) needs
   content matching (audio fingerprint, frame hashes, transcript alignment). What is
   the cheapest reliable signal?
5. **The list's shape:** how many, and in what mix of ready / near-ready / needs a
   human decision, so a session *decides* files instead of *collecting* chores? How
   does the list refill as items are decided? And what is "Angel is not working hard
   enough" as a metric?
6. **Trust:** every automatic step (verify, balance, dating by lending) must stay
   inspectable and reversible, and must never touch an original.

## Constraints

- macOS app, Swift/SwiftUI. The catalog holds ~100k records; there is **no O(records)
  work in view bodies**, and main-thread stalls are bugs.
- Media lives on many volumes: some sleep, some are offline, and FamilyArchive is
  near read-only. Per-disk pacing exists (`MediaVolumeGate`).
- Tests along five dimensions (logic, scale, media matrix, isolation, sensor).
- CI builds with Xcode 26.3 / Swift 6.2; the fleet runs Xcode 27.

## What a good answer looks like

A short design: the recommendation unit, the pipeline order (what runs before a file
is shown), the automation boundary (what the machine does unasked, what needs Rick),
a metric for "working hard enough", and a staged plan where each stage is shippable
and measurable against *files decided per session*.
