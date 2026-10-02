# Media archive: preservation, preparation, promotion, and cleanup

Consolidated 2026-09-16 from the sources listed in §15.
Baseline: `59ca9468c01e0068501206c63698286c10f4e8b7`.
This is a durable workflow and contract reference, not authorization to move or delete media.
Historical counts, dates, branch plans, and estimates are evidence of past work, not current inventory.

## 1. Purpose and status

VideoScan exists to identify irreplaceable family recordings, recover them,
preserve an original, make useful viewing copies, and reduce the surrounding clutter.
Catalog, People, triage, and Archive are views of one catalog, not separate databases.
Advancing a workflow state does not itself move a file or establish redundancy.
The long-term goal is a portable archive that Rick's family can understand without VideoScan.

Status below distinguishes documented implementation from future intent.
Source presence was checked during consolidation; no builds, tests, or live-data operations ran.

| Capability | Status at consolidation |
|---|---|
| Master Archive designation, scaffold, verified Promote, manifest/journal | Implemented; hardened recovery contracts in §5 |
| Volume role simplification and retirement separation | Implemented; §3 |
| Copy-family assessment and original/derivative distinction | Implemented core; richer role/manifest work remains separate |
| Archive timeline and Files presentation | Implemented baseline; event clustering remains proposed |
| Archive Angel preparation, durable plans, review, promotion | Implemented alpha, with subsequent scoring/rename refinements |
| Continuous Archive Angel Assessment, grades, evidence sidecar | Implemented; latest cadence supersedes nightly-only design |
| Backup attestations, protection thresholds, prune planning | Implemented through stage 2: dry run; Apply is disabled |
| Media Ledger model, store, and hooks | Implemented components; complete event coverage/portable mirroring not established here |
| Refile, final approval badges, time-budget stop | Deferred in the alpha; no completion evidence established here |
| Four-dot `ArchiveCandidacy` indicator | Proposed; existing readiness/nudge/AAA are distinct features |
| Mono-as-problem readiness correction | Still open in checked `ArchiveReadiness.assess` |
| Perceptual uniqueness ranking; original-footage classifier | Proposed; no claim of implementation |
| Automatic post-promotion deletion | Not authorized by this document and not implemented by the dry-run sheet |

### Superseded assumptions

- The May lifecycle proposal made 3-2-1 a prerequisite to promotion; the implemented
  Promote operation instead creates and verifies a local archive copy. Backup protection is separate.
- A Master Archive designation or RAID badge does not prove health or off-site protection.
- Segmented hashes identify duplicate candidates; they never prove equality for deletion or promotion.
- Full-file archive fixity is `archiveFixity`, not the segmented `contentHash` field.
- The original 03:00 Angel sweep became a continuous, idle-gated cadence.
- One star means good/bronze, not junk; human disposition and machine evidence remain distinct.
- Old “nothing built,” “next session,” and “awaiting merge” labels are historical.
  They do not override later implementation notes or the explicit status table above.

## 2. Vocabulary and preservation policy

**Asset:** the recording or memory. **Representation:** one encoding of that recording.
**Instance:** a physical copy of a representation at a location.
A duplicate-location decision and a best-original decision answer different questions.

| Representation | Role |
|---|---|
| Native DV with original PCM audio | Original source master |
| FFV1 with lossless audio made directly from that source | Optional preservation companion |
| HEVC/H.264 with AAC | Compact access/viewing copy |
| ProRes/DNx editing output | Editing derivative, unless provenance identifies it as the original |

Re-encoding cannot recover detail lost at acquisition.
A larger file, higher bitrate, higher resolution, or newer codec cannot win by itself.
A lossless encode from a lossy derivative does not recover the original generation.
A perceptual picture match does not establish equivalent, complete, synchronized audio.
An unknown lineage must remain unknown; codec class alone is a presumption.

The preservation sequence is: preserve bytes, assess condition, record evidence.
Balanced audio, deinterlacing, repair, trimming, and access transcoding create companions.
They do not silently replace an original or reinterpret fidelity as accessibility.
Mono, silence, one-sided audio, and surround can be faithful source characteristics.
A preference for stereo is not an archive requirement.

The long-term protection goal is a reliable master plus independent verified backups,
including a copy elsewhere. RAID redundancy is not a backup against deletion, fire,
theft, controller failure, or loss of the whole enclosure.
Two partitions of one device are not independent copies.
Formatting or retiring a source needs a separate, current proof that it holds no
important media or sole backup still needed elsewhere; a proposed status field is not that proof.

## 3. Volumes: intent, condition, retirement, and identity

Keep each concern separate:

| Concern | Meaning |
|---|---|
| Workflow (`VolumePhase`) | No catalog → cataloged → reviewed → consolidated → archived |
| Role (`VolumeRole`) | Intended use: Unassigned, System, Workspace, Backup, Master Archive, Cloud |
| Condition (`VolumeTrust`) | Unknown, Reliable, Aging, Unreliable; user assessment |
| Retirement (`retiredAt`) | A dated lifecycle event, independent of role |
| Reachability / media technology | Facts used by policies, not guarantees |
| Safety / suitability | Derived assessment, never a permanent declaration |

Role pickers expose Unassigned, Workspace, Backup, and Cloud.
System is assigned to the boot-volume root; Master Archive comes from Initialize.
There is one designated Master Archive per catalog.
A folder under a home directory can be Workspace without making the boot volume a workspace.
Symlinked folders retain their actual-volume reachability and space semantics.

Legacy role decoding is tolerant and idempotent:
Original/Working → Workspace; LTA/Long-Term Archive/Offsite → Cloud; Archive → Master Archive.
Legacy Retired becomes Unassigned plus a retirement stamp if none exists; a real stamp wins.
Unknown roles become Unassigned with a diagnostic, never a dropped target.
An old Archive role on a non-designated target needs user reclassification, not silent relabeling.
Reinstating a retired target does not change its role.

`VolumeSafety.isSafe` excludes retired and unreliable witnesses.
A retired drive may be retained as insurance; it must not authorize a destructive operation.
Offline copies cannot be elected for deletion or silently treated as verified surviving copies.
The dry-run protection model may count catalog-known offline devices; that count is weaker
than a fresh, reachable witness and must not be promoted into deletion authority.

Master designation persists canonical target/root paths, volume UUID, and designation date.
Scan-target IDs are per-launch and are not durable identity.
Re-resolve on load/mount by UUID, then path; enforce the current UUID before promotion.
A changed UUID, or loss of UUID reporting where one was stored, is a hard refusal.
Read-only catalogs and retired/unresolvable master targets cannot initialize or promote.

## 4. Preparing the archive and choosing an original

Initialize creates `Breen_Family_Archive/`, `00_Index/`, and empty media buckets.
The portable index contains `Archive_Inventory_Manifest.csv` and `README_Naming_and_Layout.txt`.

```text
Breen_Family_Archive/
  00_Index/
  10_Photos/
  20_Audio/1970-1979/1975/
  30_Video/1990-1999/1997/
  30_Video/Undated/
```

Video-bearing media goes to `30_Video`; audio-only to `20_Audio`; photos to `10_Photos`.
Create decade/year folders lazily. Known year gets a year folder; an uncertain year
within a known decade stays at the decade root; absent date uses the bucket's Undated shelf.
Names are `YYYY-MM-DD_Slug[_NN].ext`, with unknown month/day represented by `xx`.
Preserve the original extension, source name/path, and provenance.
A collision suffix is for genuinely different content, not a substitute for checking identity.

Use the shared `RecordDateResolver`/`ArchiveDateHint`, not an independent archive heuristic:

1. Human `userDate` at its precision; agreeing machine detail may refine, not overrule it.
2. Sanity-filtered embedded container/stream creation date, with origin-sensitive confidence.
3. Inferred date at the accepted confidence threshold (documented baseline: ≥0.6).
4. Recognized filename date/year, placed but flagged low-confidence.
5. Undated. Filesystem creation/modification dates do not determine archive placement.

Undated and low-confidence dates warn; they do not block preserving bytes.
Readiness can block an unprobeable file unless the user explicitly chooses Archive anyway.
Promotion does not transcode, repair audio, or require a date to be invented.

`CopyFamilyAssessor` collapses locations into representations and makes an ordered decision:
complete recording including audio → original generation → undamaged/complete → native
geometry/cadence/interlacing/color/audio → sustainability → location preference among equivalents.
Representation signatures include codec/container/geometry/fps/scan/channel/rate/depth.
Explicit `derivedFrom`/`derivationKind` outranks a guess based on codec era.
A family without identifiable acquisition media receives a presumed-original caution.
Full SHA-256 comparison supplies byte-equality proof; a shared segmented signature does not.

The assessor proposes; Promote remains the safe executor.
Analyze one representative per encoding after collapsing physical copies, not every pair.
Keep media work off-main; any reusable fingerprint cache is disposable evidence.
The historical SD-DV BT.709 versus BT.601/SMPTE-170M issue remains a verification item
before claiming automatic derivative color correctness; this consolidation does not close it.

## 5. Promote: execution, durability, and recovery contract

Promote is a copy, never a move. Sources remain until a separate human decision.
A promoted copy gets its own catalog identity and source lineage, inherited human metadata,
archive stage, and full-file fixity. Promotion's documented rating policy is one-way to ★★★.

The hardened `ArchivePromoteEngine` contract supersedes earlier simple copy/rename sketches:

- Open the source read-only, no-follow, regular-file only; capture device/inode/size/mtime.
- Re-check source identity after copying; a changed source does not become a verified archive copy.
- Walk destination directories descriptor-relatively with `openat(O_DIRECTORY|O_NOFOLLOW)`.
- Create directories with `mkdirat`; create partials exclusively with `O_EXCL|O_NOFOLLOW`.
- Full-file hash source and destination; verify the destination through its existing descriptor.
- Preserve timestamps, check the payload durability barrier, publish with exclusive rename,
  check the directory barrier, then durably append manifest and journal state.
- Confirm the opened descriptor still names the published file using descriptor-relative stat.
- Check every durability result. Failed barriers are errors, not “completed” files;
  failed directory durability withdraws the just-published name under the documented contract.
- Space checks, per-volume pacing, cancellation, and a per-file result remain explicit.
  Cancel removes unfinished partials; completed verified and recorded files remain.

The manifest is portable, human-readable CSV. Its original columns capture promotion time,
archive relative path, SHA-256, byte size, source path/volume, source/copy IDs, date/confidence,
people, and rating. Readiness was added as a trailing column with legacy-header support.
Do not rewrite an old manifest merely to give it a new header; append its compatible row shape.
Quote every field, flatten embedded CR/LF/control characters, and neutralize formula-leading cells.
Slug/extension restrictions and containment checks remain independent of CSV escaping.
Open the existing validated manifest through the no-follow descriptor chain, not by reopening a path.
Missing, symlinked, non-regular, or header-invalid manifests cause refusal.

`00_Index/.promote_journal.jsonl` records intent and convergence states:
**intent → renamed → published → done** (with abandonment/error handling).
Published means media plus manifest durable and catalog link present in memory.
Done is written only after a successful catalog save at batch completion.
An unsuccessful save leaves a recoverable published entry; it must not be relabeled done.

Every Promote job reconciles unfinished work first:

- File exists but row missing: verify identity/digest before appending and linking.
- Manifest exists but catalog record missing: reconstruct the link from durable provenance.
- Source is gone: reconstruct a self-contained orphan archive record, retaining unresolved lineage.
- Intent exists without final file: remove only the contained partial and abandon/retry appropriately.
- Same source already promoted: remain idempotent by source identity, not destination filename.
- Existing destination is byte-identical: adopt through the validated descriptor chain.
- Existing destination differs: choose another collision-safe name; never overwrite it.

Validate journal/manifest relative paths before reads, adoption, or removal: no traversal,
no symlinked component, and containment within an allowed bucket.
Invalid recovery entries are logged/skipped and are never advanced as successful.
Reuse a valid unused manifest record ID for the catalog join.
Imports relink provenance to the actual local stand-in; archive copies have location identity
so importing a source cannot erase its byte-identical archive copy.
Durability/UUID test seams are task-local, avoiding global-test interference.
Launch-time reconciliation beyond job-start reconciliation was deferred in the source design.

Refile remains separate: move/rename/redate within the archive, move companions together,
preserve previous paths, update manifest/catalog, and re-check fixity.
Final human approval (`approvedAt`) and removing an archive copy with retraction/confirmation
are proposed contracts, not implicit side effects of a successful Promote.

## 6. Archive Angel: assess, prepare, review

Archive Angel proposes a bounded batch; it does not decide importance or delete originals.
The implemented alpha uses count choices 10/25/35/50 and a durable SSD buffer.
The original time-budget/overnight-stop option was deferred.
Originals stay at their source until Promote; do not copy them twice just to stage preparation.

Eligibility requires usable video, an online source, and absence from the archive.
Audio-only selection is a separate future capability.
The shared archived predicate also recognizes inside-root files and content with a master copy.
Versions of archived originals can leave the to-do list; independent repairs remain visible.
Visibility is not permission to remove any file.

The floor and ranking belong in one versioned scorer, with printed reasons:

- Clips under 60 seconds are excluded from automatic Angel selection, including starred clips.
  They remain in the catalog and may still matter; “not selected” does not mean junk.
- Confirmed junk, unplayable/unprobeable candidates, recovered MXF halves, and already-archived
  equivalents are excluded; use the combined result rather than a recovered pair member.
- Cache/render/proxy naming and very low bitrate are machine evidence with documented star vetoes.
  Do not generalize those vetoes to override human junk decisions or the duration floor.
- One candidate per duplicate group per batch; ungrouped rows do not collapse.
- Derivative names yield only to a related, usable original meeting the duration comparison.
  A lone export remains eligible; do not discard the best surviving copy for its filename.
- Related-original lookup is bounded/keyed, not an unbounded folder scan.

Scores explain preference: stars, confirmed/suspected people, play history, metadata richness,
dates, long-recording tiers, at-risk format, and single-copy/storage evidence.
Weights are tunable evidence, not deletion gates or guarantees of quality.
Duration tiers favor full scenes/tapes; ranking ties use originality, date, length, size, then name.
Walk-based and evidence-based selection share the same comparator and equal-score boundary handling.
Perceptual uniqueness across edits remains proposed; uniqueness should add evidence, never reject.

Preparation order: resolve original → verify audio → balance only a fixable problem →
create access copy from repaired audio if available → optional preservation companion.
FFV1 is optional/off by default in the alpha and conditional on format risk when enabled.
Resolve the tension between a format-risk table and native-original preservation deliberately;
never claim an access codec is a better original because it is easy to play.
A failed companion step may leave an explicit original-only proposal with its failure reason.
That fallback does not waive source identity, fixity, or archive safety checks.

Plans live under `~/Movies/VideoScan Buffer/ArchiveAngel/batch-<stamp>/plan.json`,
with per-record companion directories. Persist after steps so a quit/reboot is recoverable.
The documented free-space estimate is original size ×3 before each candidate; stop cleanly
when space is inadequate and retain completed entries for review.
Cancel retains prepared rows. Discard is a distinct buffer-removal decision.
Completed companion files and review edits must never exist only on volatile RAM storage.

Review shows proposed name/date, why-lines, companion outcomes, notes, and selection.
Show in Catalog/Finder supports inspection. User edits outrank generated naming suggestions.
Following a catalog rename requires the prepared identity to agree (size/content evidence);
rewritten media is refused, and explicitly edited archive names are preserved.
At promotion, re-check source identity, eligibility, and companion availability.
Successful promotion may clear that entry's buffer; failed entries remain diagnosable/retryable.
Report originals, each companion role, failures, skips, and original-only fallbacks explicitly.

## 7. Continuous assessment and UI costs

Archive Angel Assessment (AAA) stores re-derivable evidence in
`~/Library/Application Support/VideoScan/archive-angel/evidence.json`, keyed by record ID.
The file carries version/rules-version, timestamps, counts, scores, why-lines, rejection,
and available play-history evidence. Malformed/old-rule evidence is ignored and rebuilt.
Spotlight use count is an optional signal; in-app play-count fields were deferred.

Grades: A ready ≥100; B nearly ready 60–99; C candidate 25–59;
D weak 1–24; X excluded. Catalog Archive Candidates means A+B;
Angel selection can rank A–D, subject to current floor/identity checks.
Evidence reuse requires freshness, completeness, enough candidates, and current revalidation;
stale or insufficient evidence falls back to the candidate walk.

Latest documented cadence: delayed launch (90s; 15s if missing/stale),
one minute after catalog edits, and every 15 minutes while running.
Park behind interaction (quiet gate), scans, Angel preparation, and Promote.
Project records in bounded slices; keep Spotlight/media work off-main and yield between slices.
No O(records) work in view bodies or per-row filesystem reachability calls.
Filters/Inspector use precomputed sets/maps and memo invalidation when records/rules change.
Log start, checkpoints every 5,000, and finish; per-record details stay debug-only.
The older nightly 03:00 trigger is superseded.

Proposed RAM acceleration caches one bounded source read for repeated processing,
not durable outputs/plans. Respect memory floor/headroom; oversized sources bypass it;
pressure/failure falls back to source/SSD and drains scratch.
Do not ship that path on a hypothetical throughput claim: the design requires a measured
≥25% end-to-end improvement on spinning-storage sources. It remains deferred here.

## 8. Readiness and browsing

Readiness answers playable/audio/format/date questions; candidacy answers “what next?”
AAA ranking, `ArchiveNudge`, and the proposed four-dot indicator must not become competing policies.
The proposed indicator derives Vouched, Dated, Audio verified, and Not an extra copy,
with a concrete next-action button; Archived is terminal. It is not a persisted truth.
Keep the current unprobeable override distinct from advisory date/format/audio warnings.

**Unresolved:** readiness currently interprets a nonempty note on status `ok` as a problem.
The proposed correction is to use damage status for damage and present mono/silence/surround
as information. Verify with note-by-note tests; do not silently declare this fixed.

Archive browsing presents human archive names and the archive's date structure.
The implemented timeline derives year/title from archive placement and exposes Undated honestly.
Files view remains available for archivist work; journey/reveal/play actions retain source lineage.
Future event grouping may combine neighboring dates, names, people, and tags deterministically.
Milestone photos can anchor a story without turning VideoScan into a photo library.
Event editing, photo promotion UX, family-facing publication, default sort, and uniqueness folding
remain decisions unless independently established as implemented.

## 9. Cleanup and post-promotion protection

Cleanup is a separate workflow from assessment and preservation.
Machine junk reasons, probe failure, short duration, silence, lack of faces, or a “Recovered”
folder are review signals, never proof that family footage is disposable.
An unplayable original may be the recovery mission itself.
Machine analysis writes evidence; humans decide disposition and destructive actions.
The long-term junk-deletion policy also protects above-threshold family matches
and files another volume still relies on as a backup. Missing detections do not waive those gates.
Archive/cloud preservation storage is outside generic scratch-copy cleanup authority.

Before a bulk pass, create a current catalog backup and inspect a bounded dry run.
Preserve human dates, people, stars, notes, tags, and provenance on the verified survivor.
Recompute keep election after volume retirement or precedence changes; an offline keeper
must not strand the only reachable copy. Partial hashes and confidence labels cannot authorize removal.

At a duplicate-deletion boundary, full-hash **both** keeper and candidate immediately before action.
Require stable identities through that boundary; historical sequential-hash TOCTOU concerns remain
an audit item until the specific caller proves descriptor/inode/time revalidation.
A matching sampled head/middle/tail hash is only a candidate; differing samples reject equality.
Near-duplicate/transcoded/trimmed versions are never automatically deleted as exact copies.
Recovered A/V pair members, archive-root files, sole masters/backups, and human keep evidence
require their specific preservation gates; a generic cleanup score cannot waive them.

Minimum surviving copies and physical-device independence are policy, not volume-name counts.
Old cleanup plans proposed two or three copies on two physical stores and blocking offline clusters.
The newer prune planner uses importance thresholds; neither historical proposal licenses an executor
without fresh byte verification, reachability/identity checks, and explicit reviewed approval.

Prefer macOS Trash plus soft-delete metadata, journal, and Undo for reviewed cleanup.
Do not silently fall back to permanent deletion when Trash is unavailable on a network volume.
A permanent path needs separate explicit confirmation and the same verification protections.
Catalog removal alone must not be misrepresented as freeing disk space or deleting media.
Keep the audit memory that a file existed and what happened to it.

### Implemented prune planning, not deletion

`ArchivedWhatNextSheet` appears after verified batch completion; its Apply button is disabled.
`PrunePlan` computes an off-main, reviewable candidate plan and protection line.
Backup attestations are human yes/no/not-applicable answers for cloud, off-site, or named storage;
they are not app-verified fixity. Preserve them through rescan and same-footage inheritance.

Default importance bars in the planning model:

| Importance | Required protection before proposing extra-copy removal |
|---|---|
| Important: ★★★ / Important disposition | Verified archive + another device + cloud/off-site attestation |
| Ordinary: ★★ / unrated | Verified archive + another device |
| Low: ★ / Recoverable | Verified archive |

A human note is an absolute keep in the planner; Important disposition chooses the higher bar.
Do not confuse this newer model with the earlier scrub proposal's absolute “no stars/Important” rule.
Candidates exclude archive-root files, offline targets, pair members, versions, and unverified families.
Retain versions even when hidden from the to-do list; independent repairs are not ordinary versions.
Keep-one selection prefers a connected working volume with free space and the original over versions,
with an explicit user override. Families below the bar keep their copies.

Future stage 3 needs a reviewed per-run cap (proposal: 200; earlier scrub proposed 500),
Trash/Undo, an approval record listing files, and protection/attestation snapshots per action.
Cloud checking could later upgrade an attestation to verified evidence; it is not implicit today.
Media Ledger's contract is append-only dated events and portable archive history,
including approval, promotion/fixity, set-aside/restore, and copy removal.
Complete event wiring, archive `00_Index` mirroring, Hallie history answers, and manifest
place/attestation columns must be checked individually; component existence does not complete the plan.

## 10. Recovery lessons retained from the cleanup runbooks

The August plans were executions against particular media, not reusable shell instructions.
Keep their original evidence in history; never replay their paths/counts as a current work list.

- August 11–13: sampled hashing became a dedicated resumable hash-only backfill;
  probe-cache hits had bypassed hashing and could erase new signatures on rescan.
  Cache persistence and authoritative hashing at destructive boundaries both matter.
- August 18: redistribution adopted existing copies and copied missing ones, preserving provenance.
  Rescanning sources then created bare twins; cleanup had to carry metadata onto surviving copies.
- Whole-file verification refused cross-container “high-confidence” transcodes that differed.
  The byte gate, not keeper scoring, prevented their deletion.
- Lost per-file rotation logs, cancellation stalls, dangling post-force-quit records,
  and catalog generation regression showed why recovery and durable audit matter.
- Historical outstanding work included moving remaining source trees, reconciling catalog paths,
  consolidating Avid media as intact trees, and retiring staging copies only after verification.
  No completion claim for those operations is made here.

Working-set storage and archive storage are different roles. Non-media personal storage
should remain outside media scan/purge scope. Hardware partition sizes and old device rankings
are historical decisions, not fresh recommendations; see the separate storage document.
Do not move an Avid media tree piecemeal or treat a recovered half as expendable;
use the dedicated format/recovery and relocation contracts.

## 11. Original-footage classification remains proposed

A reversible camera/tape/slideshow/screen-recording/unknown classifier could reduce search noise.
Use metadata, frame/scene cadence, transcripts, and captions as fallible evidence.
Sample rate, frame rate, codec, resolution, low bitrate, or missing audio cannot alone prove a class.
The original scorecard's categorical camera/slideshow claims require calibration, not blind adoption.
Human correction must be possible, and classification must not delete or permanently exclude media.
The existing video/audio facet is not this proposed classifier.
Faces shown inside slideshow photographs also require a separate person-presence evidence policy.

## 12. Required validation for future changes

- Logic: eligibility, role/date/name rules, identity refusal, manifest escaping, state convergence.
- Scale: 100k records with explicit budgets for catalog traversals, precomputed lookup/filter sensors,
  bounded children/cancellation, no main-thread per-record disk work, and memo invalidation.
- Media: synthetic MP4/H.264, MOV/ProRes, MKV/FFV1+PCM, MXF, AVI/DV where bytes are opened.
- Isolation: injected scratch stores, poisoned shared settings/designations, no live catalog writes.
- Sensors: every safety gate must have a refusal case; corruption/source replacement/barrier failure,
  duplicate promotion, legacy manifest/import recovery, and human metadata preservation must stay pinned.

Historical pass counts in the source documents are not current validation results.
No validation suite was run for this documentation consolidation.

## 13. Outstanding decisions and work

Refile/approval; richer companion roles and portable manifest evolution; audio-note readiness;
original-footage classification; perceptual uniqueness; complete Ledger coverage/mirroring;
post-promotion deletion policy/executor; automated-delete race audit; cloud verification;
event grouping/family publication; measured RAM scratch; and timeline/edit UX remain individually tracked.
Do not infer their completion from the presence of an archive, an alpha batch, or a clean-looking catalog.

## 14. Separate authoritative references

- [Relocation and reconcile](relocate_volume_plan.md): cross-volume movement and witness contracts.
- [Catalog write safety](catalog_write_safety_design.md): persistence, locking, recovery, and generation safety.
- [Database design](database_design.md): authoritative catalog versus disposable caches.
- [Avid format research](Avid-Format-Reverse-Engineering.md): essence/recovery details.
- [Storage hardware](storage_raid_recommendations.md): hardware decisions; re-evaluate before buying/repartitioning.

## 15. Provenance

Original filenames below are retained for historical lookup at baseline
`59ca9468c01e0068501206c63698286c10f4e8b7`; later source status takes precedence over old plans.

- `docs/archive-view.md` — archive timeline intent and remaining event/photo questions.
- `docs/archive_angel_alpha_status.md` — alpha implementation and deferred scope, September 9–10.
- `docs/archive_angel_design.md` — scoring, floors, batch/companion/buffer/approval contracts and revisions.
- `docs/archive_angel_phase2_design.md` — assessment evidence, grading, scheduling, logging, and rev-2 cadence.
- `docs/archive_angel_uniqueness_direction.md` — original/unique content priority; future uniqueness signal.
- `docs/archive_promotion_workflow.md` — master designation, portable layout, five rounds of safety/recovery refinements.
- `docs/archive_readiness_indicator_design.md` — advisory candidacy proposal and unresolved audio-note issue.
- `docs/archived_duplicate_scrub_design.md` — conservative scrub candidates; superseded deletion planning.
- `docs/promote-helper-workflow.md` — original-versus-derivative rationale and fidelity hazards.
- `docs/promote_helper_plan.md` — pure assessor, representation model, and staged implementation.
- `docs/promote_and_prune_workflow_design.md` — protection bars, attestations, staged deletion, and Ledger contract.
- `docs/media_lifecycle_manager.md` — lifecycle/triage axes; superseded strict 3-2-1 promotion proposal.
- `docs/media_longterm_plan.md` — family preservation purpose, independent backups, and safe retirement goal.
- `docs/plan_2026_08_11_cleanup_and_gold_archive.md` — hashing correction, cleanup ordering, deletion invariants.
- `docs/plan_2026_08_16_archive_init_and_redistribute.md` — historical initialize/backup/redistribution sequence.
- `docs/runbook_2026_08_18_catalog_cleanup.md` — execution evidence, metadata carry-over, refusals, outstanding moves.
- `docs/volume_taxonomy_proposal.md` — implemented role migration and retirement/safety separation.
- `docs/issue-08-bad-file-triage.md` — early triage/filter proposals; unsafe heuristic certainty not carried forward.
- `docs/video_classification.md` — proposed reversible original-footage classifier.

Status spot-checks used `ArchiveTimelineModel`, `ArchiveView+Timeline`, `CopyFamilyAssessor`,
`ArchiveAngel*`, `ArchiveReadiness`, `ArchivedWhatNextSheet`, `PrunePlan`,
`BackupAttestation`, `MediaLedger*`, and `MediaKindFacet` source at the consolidation baseline.
