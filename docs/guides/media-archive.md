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

- [Relocation and reconcile](../design/relocate_volume_plan.md): cross-volume movement and witness contracts.
- [Catalog write safety](../design/catalog_write_safety_design.md): persistence, locking, recovery, and generation safety.
- [Database design](database_design.md): authoritative catalog versus disposable caches.
- [Avid format research](../design/catalog.md): essence/recovery details.
- [Storage hardware](../research/storage_raid_recommendations.md): hardware decisions; re-evaluate before buying/repartitioning.

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

## 16. Archive Angel recommendation policy (schema 2)

*From `guides/archive_angel_policy.md` (Rick 2026-09-22; rules to v15, 2026-10-06), whole; merged here 2026-11-01. The Swift sources cite it as the user-facing reference for the rule set.*

### Archive Angel recommendation policy (schema 2)

Rick 2026-09-22: *"the AA selection criteria should be easily programmable so we can add/delete/change the criteria as needed… not hard coded, a user should be able to… guide the app on how it recommends."*

Every criterion the Archive Angel uses to recommend a file is **data** in one JSON rule set. You can change a number, switch a rule off, or add a rule of your own, without touching Swift.

#### Where it lives

| Source | Path | Notes |
|---|---|---|
| Your override | `~/Library/Application Support/VideoScan/archive-angel/policy.json` | Optional. The app never creates it. |
| Bundled default | `ArchiveAngelPolicy.default.json` (in the app) | Byte-identical to the compiled-in rules (a test pins it). Copy entries from it as a starting point. |
| Compiled-in | `AngelRecommendationPolicy.builtIn` | Used if both files are unusable. |

The file is read once, when the app starts — off the main thread, so a bad file can never freeze the app. It must be a regular file (a symlink to one is fine) of at most 1,000,000 bytes; the app never reads more than that. Until it has loaded (a few milliseconds), assessment waits and Prepare asks you to try again. **Quit and relaunch after editing it.**

**Refused, never half-read.** If your file cannot be read or parsed, or anything in it is unknown (a kind, a field, an operator, a value of the wrong type, a choice that isn't one of the field's values, a number out of range, a bad stem pattern), the whole file is refused. The console and `videoscan.log` name every problem, and the bundled default runs instead. A key the app doesn't read (a typo like `"pionts"`) doesn't refuse the file; it is named in a notice.

**When the rules change, everything is re-scored.** The evidence sidecar is stamped with the policy's fingerprint. A different policy means a full re-score at the next sweep, which takes a few seconds.

#### Your file holds only what you change

Your file is **merged over the built-in rules**:

- Objects (`weights`, `grades`, `tables`, `recommend`, `recommend.date`, `recommend.copies`) merge key by key.
- Rule lists (`floors`, `signals`, `recommend.exclude`, `recommend.vouch`) merge **by `id`**:
  - an entry with a built-in rule's `id` edits that rule in place (`{"id": "recentPhoneClip", "enabled": false}` switches it off);
  - an entry with a new `id` adds a rule. A new **signal** goes just before the `downloadCap` / `fatigue` adjusters. Anything else goes at the end.
- Everything else (`recommend.classes`, `tables.originality`, single values) replaces the default.

`"schemaVersion": 2` is required, as an integer (`true`, `2.0` and `"2"` are refused). A schema-1 file (just `weights`) is still accepted: its weights are used with today's default rules, and a notice says so.

So the smallest useful file is:

```json
{ "schemaVersion": 2, "name": "longer clips only", "weights": { "minimumDurationSeconds": 300 } }
```

#### How a recommendation is made

1. **Floors** (`floors`) are checked in order. The first one that fires excludes the file, and its reason is the one you see.
2. **Signals** (`signals`) each add one printed evidence line. The score is the sum of the lines.
3. **Grades** (`grades`) turn the score into a letter: A ≥ `a`, B ≥ `b`, C ≥ `c`, D ≥ `d`, otherwise X.
4. **Classes** (`recommend`) put every file into exactly one class. These classes are the only numbers the app shows: the Angel strip's "N ready · M need a date · K prepared", the catalog's badge, and Show ▸ Archive Candidates.

| Class | Default rule |
|---|---|
| **Worth a look** (`absurdBitrate`, rules v12) | Would be recommended (vouched, or grade A/B) but averages 1 Gbit/s or more — a broken encode (a 43 GB file for 37 s) until you have looked. Reason: "Unusually large for its length — check it before archiving" |
| **Needs a date** (`recentDigitization`, rules v12) | Would be Ready, but the machine's date is within the last year, no camera or phone is named in the tags (neither a make nor a model — `hasCameraOrigin`), no date of yours, and the codec is a digitizer's or an editor's (FFV1, ProRes, DV, MPEG-2, MJPEG) — a tape converted this year, dated by its conversion. Reason: "Dated 2026, but it looks like a digitization of older footage — confirm when it was filmed". A year you type ends it |
| **Ready** | Passes the floors, AND (someone vouched: Important, ★★ or more, stage Ready/Master, OR grade A), AND dated to at least a year |
| **Needs a date** | Same as Ready, but not dated |
| **Worth a look** | Grade B, nobody vouched |
| **Not now** | Grade C/D, or nothing recommends it |
| **Excluded** | A floor fired (including the default `extraCopy` floor: a copy you marked Extra copy — switchable, not a safety floor), or an `exclude` rule matched |
| **Another copy** | The same recording as a recommended copy (same footage group from Find Similar Footage, same duplicate group, or same name + length). The copy you marked Keep wins; then, in a footage group, its likely original; otherwise the best-ranked copy does. |
| **Prepared** | Sitting in a prepared batch, waiting for your review |

5. **Coverage** (`coverage`, rules v13; event labels v14) shapes each *batch* Prepare builds, after the ranking: one pick per **day or labelled occasion** (Christmas 1994, Timmy's birthday 1994), at most `maxPerYearPerBatch` picks per **year**. Neither is an exclusion — a row held back this way waits for a later batch, and a batch is never left short for it (see below).

archiveStage Ready/Master is a **vote** to archive. Only a real Master Archive copy (`onMasterArchive`, `archivedCopy`) means "already archived".

#### Safety floors — these cannot be turned off, by design

Six floors guard against recommending a file the archive must never receive twice or cannot receive at all (the delete-safety principle: refuse over guess):

| Floor | Excludes |
|---|---|
| `notVideo` | audio-only files, stills, un-probed files |
| `onMasterArchive` | a file in the Master Archive, or one that already has its copy there |
| `angelWorkingCopy` | a companion Archive Angel prepared in its own buffer (`~/Movies/VideoScan Buffer/ArchiveAngel`) — never material of its own (rules v12) |
| `archivedCopy` | a file whose content (or original) is already archived — including the other members of a **footage group** (Find Similar Footage, Likely or stronger) whose likely original is archived (rules v12) |
| `fileGone` | a record Relocate marked Manually Deleted or Salvage Failed |
| `volumeOffline` | a file on a volume that isn't mounted |

A `policy.json` that disables one of these, narrows it with `when`, sets `starExempt`, sets `explicitPicks: false`, or changes its kind or reason is **refused whole**. The log names the safety floor, and the bundled default runs. `recommend.useAngelFloors: false` still honours them. You may change their `note` and `line`.

**The safety floors are their own pass** (codex #1643). The reason a file shows is the *first* floor that fires in policy order — so an offline 30-second tape reads "Too short", the lasting reason, not "Volume offline". But every file is also checked against the six safety floors separately, and that result is stored on its own. The classes exclude a file on any safety hit, whichever floor fired first and whatever `useAngelFloors` says.

Separately from the floors, the recommendation counts are re-checked against the live catalog about half a second after any catalog change. A record that has been purged, set aside or superseded, or that Promote would refuse (already promoted, an archive copy), stops being counted, listed or badged immediately. It doesn't wait for the next sweep. The counts, the catalog filter, the row badge, the record's class and Prepare all read **one** effective class — the stored class, then the prepared/promoted batches, then this live check — so a badge can never say "Promote me" for a file the counts left out.

Prepare also looks at copies live. If you mark a different copy **Keep** after the last assessment (A was Ready, B was Another copy, you mark B Keep), Prepare re-decides that recording's copies from the current catalog and prepares B — it doesn't wait for the next sweep.

#### Rules

A rule is an object. Only `id` and `kind` are required.

| Key | Default | Meaning |
|---|---|---|
| `id` | — | Unique in its list; how an override refers to the rule |
| `kind` | — | What the rule does (tables below) |
| `enabled` | `true` | `false` switches the rule off |
| `when` | `[]` | Conditions, all of which must hold. Required for `match`. On a built-in kind, it narrows the rule to the files it names. |
| `points` | `0` | `match` signal: points (−10000…10000). Vouch: points (a `stars` vouch gives this many per star). |
| `line` | `""` | The text shown: the evidence line, the vouch reason, or the exclusion reason |
| `note` | `""` | Free text for people: why the rule exists |
| `starExempt` | `false` | Floors only: a file with any star passes this floor |
| `explicitPicks` | `true` | Floors only: `false` means the floor applies to the Angel's own proposals, not to "Prepare with Archive Angel" on files you selected |
| `vouches` | `true` | Vouch rules only: `false` means a note, not a vouch (for example "the copy to keep") |
| `rejection` | none | `match` floors only: report a built-in reason by name (`"tooShort"`, `"alreadyArchived"`…). If omitted, the reason is "Excluded by a rule in your recommendation policy" followed by the rule's `line`. |

##### Floor kinds (`floors`)

`match`, `notVideo`, `onMasterArchive`, `angelWorkingCopy`, `archivedCopy`, `notPlayable`, `pairedHalf`, `noSound` (rules v15 — see below), `livePhotoMotion`, `recentPhoneClip` (`weights.recentPhoneClipYears`), `appCache` (`tables`), `derivativeOfOriginal`, `tooShort` (`weights.minimumDurationSeconds`; explicit picks use `explicitPickMinimumDurationSeconds`), `proxyStream` (`weights.minimumAverageKilobitsPerSecond`), `markedJunk`, `suspectedJunk`, `junkScore` (`weights.junkFloor`), `volumeOffline`, `resting` (the attention memory).

##### Signal kinds (`signals`)

`match`, `stars`, `confirmedPeople`, `machinePeople`, `playHistory` (`playHistoryPerDoubling` × log2(1+plays), capped, plus the recent-play bonus inside `playedRecentlyDays`), `richness`, `date`, `duration` (the tape tiers), `formatAtRisk`, `onlyCopy`, `unassignedVolume`, `audioProblem`, `backlogBonus` (rules v13 — see `coverage`), `downloadCap`, `fatigue`.

`downloadCap` and `fatigue` act on the total of the lines above them, so keep them last.

##### Vouch and exclude kinds (`recommend.vouch`, `recommend.exclude`)

- Vouch rules can use `match` or `stars`.
- Exclude rules can use `match` only.

#### Conditions

A condition is `{ "field": …, "op": …, "value": … }`. To say "any of these", write `{ "any": [ condition, … ] }`. All the conditions in a `when` list must hold. Text is compared case-insensitively. A number the file doesn't have (for example `year` on an undated file) never matches.

| Type | Fields | Operators | Value |
|---|---|---|---|
| text | `filename` `path` `videoCodec` `deviceModel` `volumeName` | `==` `!=` `contains` `notContains` `hasPrefix` `hasSuffix` · `in` `notIn` | a string · a list of strings |
| number | `durationSeconds` `durationMinutes` `sizeMB` `averageKbps` `starRating` `junkScore` `tagCount` `useCount` `peopleCount` `year` (yours, else the inferred date) `captureYear` (camera/phone stamp) `yearsAgo` (this year minus the year the one date rule places the file under — the year Promote would file it by; unknown when undated, so it never matches) `duplicateGroupCount` | `==` `!=` `<` `<=` `>` `>=` | a number |
| names | `people` (confirmed) `machinePeople` (detected + suspected) | `contains` `notContains` · `in` `notIn` | a string · a list |
| choice | `mediaDisposition` (unreviewed, important, recoverable, suspectedJunk, confirmedJunk) · `archiveStage` (none, healthy, masterAssigned, backedUp, readyForArchive, archived, manuallyDeleted, salvageFailed) · `duplicateDisposition` (none, keep, review, extraCopy) · `volumeRole` (unassigned, system, workspace, backup, cloud, archive) | `==` `!=` `in` `notIn` | a case name, or the label the app shows ("Suspected Junk") |
| true/false | `isPhoneClip` `isLivePhotoMotion` `isHumanMarked` `hasUserNotes` `formatAtRisk` `isOnlyCopy` `isPairedHalf` `volumeOnline` `isOnMasterArchive` `hasArchivedDuplicate` `hasDuplicateGroup` `hasUserDate` `hasCaptions` `hasOCRText` `hasCameraOrigin` | `==` `!=` | `true` / `false` |
| class rules only | `grade` (A–X) · `eligible` · `vouched` · `dated` · `vouchPoints` | as above | |

#### `recommend`

| Key | Default | Meaning |
|---|---|---|
| `useAngelFloors` | `true` | A floor exclusion (grade X) makes the file Excluded |
| `exclude` | Extra copy | Exclusions that only apply to the classes |
| `vouch` | Important 3 · ★★+ 1 per star · stage Ready 2 · stage Master 1 · Keep (a note) | Who vouched, and how strongly |
| `date.minimum` | `"year"` | `day` / `month` / `year` / `decade`, or `readinessKnown`, which asks Promote's own date check (ArchiveReadiness) |
| `classes` | absurdBitrate, recentDigitization, Ready, Needs a date, Worth a look (see above) | Ordered. The first match wins; no match means Not now. A class rule may carry a `line` — the reason a person reads when that rule assigns the class; `{year}` in it is replaced by the date rule's year ("undated" when there is none). |
| `copies.collapseBy` | `footageGroup`, `duplicateGroup`, `nameAndDuration` | How copies of one recording are recognised. `footageGroup` = the group **Find Similar Footage** recorded (copies, re-encodes, transcodes, exports of one recording); `sharedDuplicateGroup` = only duplicate groups of two or more |
| `copies.prefer` | `userKeeper`, `footageOriginal`, `best` | Which copy stays. `footageOriginal` = the footage group's likely original (the lowest rank Find Similar Footage gave) |
| `order` | `angelRank` | The order of the lists: `angelRank` (score, then most original) or `vouchPoints` (the old nudge's order) |
| `prepare` | `["ready", "worthALook"]` | The classes Prepare Batch takes, in this order: class first, then score. Add `"needsDate"` to opt in to undated keepers. Within a duplicate group, the copy you marked Keep is prepared. |

##### One recommendation per footage group (Find Similar Footage, 2026-09-23)

When **Find Similar Footage** has run, every file it grouped carries its footage group and its rank in it (0 = the likely original). With the defaults above:

- only groups Find Similar Footage rated **Likely or stronger** collapse; a Possible group is shown to you, never decided for you;
- keys are merged: a file in a footage group AND a duplicate group joins both, so a byte copy seen only through its duplicate group and its twin seen through the footage group are one recording (never two Ready rows, never both in a batch);
- the recommended lists, the counts, the catalog badge and Show ▸ Archive Candidates show **one** file per footage group — the copy you marked Keep, else the group's likely original, else the best-ranked — and the others become **Another copy** ("Same footage as X — that one is recommended");
- a prepared batch takes at most one member of a footage group (the same rule as a duplicate group).

**To turn it off**, list the collapse keys without it:

```json
{ "schemaVersion": 2, "name": "no footage groups",
  "recommend": { "copies": { "collapseBy": ["duplicateGroup", "nameAndDuration"],
                             "prefer": ["userKeeper", "best"] } } }
```

The groups are metadata guesses (Identical / You confirmed / Likely / Possible). Nothing about them lets the Angel archive, delete or date anything; they only decide which copy is *recommended*.

#### `coverage` (rules v13, 2026-09-26)

Rick: *"If AA recommends 5 different versions of the same Thanksgiving 1994, rather than misc birthdays, trips, christmas from other years not yet archived, then AA is not working that well."* Everything here is additive: a `policy.json` written before v13 reads exactly as it did, with these defaults.

| Key | Default | Meaning |
|---|---|---|
| `onePerEvent` | `true` | One pick per **day** (rules v14: or labelled occasion — `eventLabels`) per batch. The day is the ONE date rule's answer at day precision — your date, a camera's or phone's stamp, or the dossier's inferred date. A month, a year, a transcoder's stamp (the day a *copy* was made) or no date at all is **not** a day: such rows never collapse. Whatever the name or folder, two files shot on the same day are one event for this rule — a *diversity* choice, never "a copy" and never "already archived". |
| `maxPerYearPerBatch` | `2` | At most this many picks of one year per batch, so a batch spreads across the years still to archive. `0` = no cap. Rows with no year are not capped (there is no year to spread them over). |
| `backlogBonusMax` | `20` | The `backlogBonus` signal: a year with a deep backlog and few archived files earns up to this many points, scaled by the share of the year's recordings still to archive (2010 with 156 to archive and 27 archived → 17 points; a year half archived → 10). `0` switches it off. |
| `backlogMinimumUnarchived` | `10` | A year earns the bonus only with at least this many recordings still to archive. |
| `eventLabels` | `true` | Rules v14. `onePerEvent`'s event is a labelled **occasion** as well as a day — a holiday, a family birthday, a name word with the year (see *Event labels* below). Two Christmas-1994 files shot on the 24th and the 25th, and an `xmas94` tape with only a year, are one event; two files of one day still are. `false` = rules v13's day rule exactly (same keys, same picks). |
| `birthdayWindowDays` | `3` | A day within this many days of a People-tab birthday is that person's birthday. `0…14`. |

##### Event labels (rules v14, 2026-09-29)

Derived each time from what the catalog already knows — nothing is stored on a record and no background job runs (VideoScanCore `EventLabeler`, one pure type). Each label carries where it came from and a reason line, and the **Archive Readiness** sheet shows it as an *Occasion* line: `Christmas 1994 (Dec 25 — Christmas; file name says 'xmas')`.

- **Calendar** — only from a day-precise date the day rule trusts (the same rule as the day key: never a transcoder's copy stamp). Christmas Dec 24–26 · New Year Dec 31–Jan 1 (New Year's Eve belongs to the *new* year) · Thanksgiving, the 4th Thursday of November ±1 day (US rule for every year) · Easter Sunday ±1 (Gregorian computus) · the Fourth of July, Jul 3–5 · Halloween, Oct 31 · Mother's Day (2nd Sunday of May) · Father's Day (3rd Sunday of June).
- **Birthday** — the same trusted day within ±`birthdayWindowDays` of a People-tab birthdate, in a year after the birth year and not after a known death year: `3 days after Timmy's 12th birthday`. A Feb 29 birthday is kept on Feb 28 in common years; across New Year the nearest anniversary wins (Dec 30 is 2 days before a Jan 1 birthday of the *next* year). Several people → a label each. The birthdays are read the way Hallie reads the People tab — read-only, never migrating anything — off the main actor when the Angel starts and before each assessment. A birthdate stored as exactly midnight UTC (a hand-edited `profile.json`) is read as that day; anything else in the Mac's own calendar (what the People sheet's date picker stores).
- **Name** — a curated word list in the file name (extension dropped) and the two nearest parent folders (never the `/Volumes/<drive>` or `/Users/<you>` part): `xmas`/`christmas`, `bday`/`birthday`/`party`, `thanksgiving`, `easter`, `halloween`, `wedding`, `graduation`, `vacation`/`trip`/`roadtrip`, `beach`, `lake`/`lakehouse`, `cape`, `disney`/`disneyland`/`disneyworld`, `camp`/`camping`/`campout`/`campground`/`campsite`/`campfire`, `recital`, `game` (and simple plurals). Whole words only, any case; digits, spaces and punctuation break words and so does a camelCase hump (`xmas94_tape2` → *xmas*; `ChristmasMorning` → *christmas*). A name word needs only a **year** — `xmas94_tape2.mov` whose year is 1994 is *Christmas 1994* — but never lends itself to a copy-era stamp's year, and a word with no year keys nothing (Christmas across fifty years is fifty events).
- **Judgement calls.** `capetown`, `partyline`, `gamecube`, `endgame`, `campbell`, `escape` are *not* events (whole words). `Cape Town` *is* cape and `GameCube` is *game* + *cube* — accepted: the family's Cape is the Cape, and a hump is a word break. `party` counts as a birthday only when nothing else in the same name is an event word (`xmas party` is Christmas).

**How the key changes.** Rules v13 keyed an event by its day, `d:1994-12-25`. With labels on, a labelled file's key names its occasions *and* its day, `e:christmas:1994|d:1994-12-25` (a birthday: `e:birthday:timmy:1994`), and a row is held back when **any** of its keys is already in the batch. So every v13 same-day collapse still happens and a labelled occasion collapses across its days too. Unlabelled files keep the v13 key byte for byte. The labels never change a score or the ranked order — the pass runs after the ranking, like the rest of `coverage` (codex #1643 A4).

**Recordings, not files.** The backlog counts unique recordings — one per duplicate group, and per footage group when the policy collapses by it (never by name + length). Importing a thousand copies of one 1994 tape adds one recording to 1994, not a thousand. A recording counts as *archived* when any copy, its content or its footage's original is in the Master Archive; as *to archive* when it is not and some copy is real material: a video, not junk (marked or suspected), not Archive Angel's own working copy, not a Live Photo motion half, not a file Relocate reports gone, and at least `weights.minimumDurationSeconds` long. Recordings nobody can date have their own bucket — reported in the log, never rewarded.

**Soft, never short.** Both batch rules hold rows back for a *later* batch; they never exclude. When the rows within the rules are fewer than the batch asks for, the best held-back rows fill it (a partial batch reads as "nothing to do"). Only rows still held back are counted, under "Another pick from the same day is already in this batch — spreading picks across events" and "Held for a later batch — this batch already has its share of that year". The ranked order is never changed by these rules (codex #1643 A4): they run after it.

**The cache and the walk agree.** Prepare's cached pick reads past its score band for rows of years that still have room (rows of a year at its share cost a lookup, never a projection), and finishes the band it stops in so equal scores never decide which rows were read. When it would have to fill a batch from rows it never read — or when the catalog changed since the sweep's snapshot (the evidence file's `catalogRevision`) — it declines and the job walks the catalog, which applies the same rules over everything. With every coverage key off, the pick behaves exactly as in rules v12.

Off, as a file would write it:

```json
{ "schemaVersion": 2, "name": "no coverage",
  "coverage": { "onePerEvent": false, "maxPerYearPerBatch": 0, "backlogBonusMax": 0 } }
```

Event labels off, everything else as it is (rules v13's day rule):

```json
{ "schemaVersion": 2, "name": "days only", "coverage": { "eventLabels": false } }
```

#### `grades` and `tables`

- **`grades`**: `{a: 100, b: 60, c: 25, d: 1}`. They must rise.
- **`tables`**:
  - `originality` (codec → rank, 0 = most original; a tie-break only)
  - `originalityUnknown`
  - `deliveryCodecs` (used by the download cap)
  - `familyOriginFolders` (a leading `.` matches a suffix, like `.imovielibrary`)
  - `appCacheFolders` (rules v12 adds `personsearchresults`, Person Finder's output folder)
  - `appCacheStemNames`, `appCacheStemNumbered`, `appCacheStemGlobs` — what counts as an app's cache/render file by its **stem** (the filename without its extension). Compared case-insensitively, always against the whole stem:
    - `appCacheStemNames`: bare tool nouns (default `cache render proxy proxies preview thumb thumbnail temp tmp`). `Cache.mov` matches; `Cache Cod 1998.mov` does not.
    - `appCacheStemNumbered` (default `true`): a noun may carry a number — one optional separator (space, `_` or `-`) and then digits: `Cache-30`, `render_7`, `tmp12`.
    - `appCacheStemGlobs` (default `*_compilation_*` — Person Finder's `Donna_compilation_39_h264_720p…` exports, rules v12): extra patterns. Literal text, where `*` means "any characters": `render*` (starts with), `*_proxy` (ends with), `clip*final` (both), `*cache*` (contains). At most one `*`, or exactly two when they are the first and last character. A pattern of only `*` is refused (it would match every file). Up to 100 patterns and 500 names, each at most 100 characters.

    **There are no regular expressions in the policy** (codex #1643). A user-supplied pattern could freeze the app: one passed every check and then took more than 2 seconds on a 30-character name, and another hung the check itself. These stem rules are matched in time proportional to the name's length, whatever you write. The defaults match exactly what the old pattern `^(cache|render|proxy|proxies|preview|thumb|thumbnail|temp|tmp)([ _-]?\d+)?$` matched (a test pins this).

    An older file that still has `appCacheNamePattern`: if it is exactly the old default (copied from the bundled file), or a plain list like `^(Scratch|Render Temp)$`, it is read as the same rule and a notice asks you to rename the key. Anything else refuses the whole file, with the reason.
  - `maxOriginalsPerKey`

#### Deliberately NOT in the policy

The policy says **what** to recommend, not how the machine paces itself. These stay in code and change only through code review, because they protect the Mac's memory and your attention:

- the sweep cadence (at launch, 1 minute after an edit, every 15 minutes, in slices of 500 records);
- evidence freshness (24 h);
- the fresh-slot scan budget (200);
- the attention memory's cap of 12 events per file;
- the buffer rules;
- Angel Checks' pacing (docs/design/archive_angel_wise_design.md §4): the top 20 recommendations are looked at, one Verify Audio at a time, only after 120 s without you touching the app (the Catalog's thumbnails and every Archive Angel button count as touching it) and while no other file operation of any kind is running, at most 12 checks started an hour and 200 started per launch (a skipped file — missing, already being verified — costs nothing), each file at most once per launch. A Prepare pressed while a check reads that same file waits for the check's verdict instead of being refused. The switch ("Check Sound in the Background", `archiveAngel.checksEnabled`) is a preference, not a policy rule;
- Keep footage groups current (§5): Find Similar Footage runs once after the first complete assessment of a launch when the last automatic run started more than a day ago (or never — the time is kept in `archiveAngel.footageLastAutoRunAt`), and again after a catalog change at most every 6 h (`archiveAngel.footageAutoEnabled`).

#### Worked examples

Each example below is a complete `policy.json`. The test suite loads these exact texts (`AngelRecommendationPolicyTests`, "WORKED EXAMPLE 1–3").

##### 1. Never recommend clips under 5 minutes

```json
{
  "schemaVersion": 2,
  "name": "Rick: nothing under 5 minutes",
  "floors": [
    { "id": "underFiveMinutes", "kind": "match",
      "when": [ { "field": "durationMinutes", "op": "<", "value": 5 } ],
      "line": "Under 5 minutes — usually a piece of a longer original",
      "explicitPicks": false }
  ]
}
```

- It applies to starred files too (no `starExempt`).
- A clip you select yourself and send with "Prepare with Archive Angel" still goes (`explicitPicks: false`).
- The one-number alternative is `"weights": { "minimumDurationSeconds": 300 }`. The difference: that raises the built-in `tooShort` floor and reports "Too short".

##### 2. Boost anything with Donna

```json
{
  "schemaVersion": 2,
  "name": "Rick: Donna first",
  "signals": [
    { "id": "donna", "kind": "match",
      "when": [ { "any": [ { "field": "people", "op": "contains", "value": "Donna" },
                           { "field": "machinePeople", "op": "contains", "value": "Donna" } ] } ],
      "points": 40, "line": "Donna is in it" }
  ]
}
```

- The rule adds 40 points and prints "Donna is in it".
- It is placed before the download cap automatically.
- 40 points lifts a C (25–59) to a B, or a B to an A. To make her files Ready whatever their score, add a vouch rule instead, under `"recommend": {"vouch": [ … ]}`.

##### 3. Ignore 2020s phone clips

```json
{
  "schemaVersion": 2,
  "name": "Rick: no 2020s phone clips",
  "floors": [
    { "id": "phone2020s", "kind": "match",
      "when": [ { "field": "isPhoneClip", "op": "==", "value": true },
                { "field": "captureYear", "op": ">=", "value": 2020 } ],
      "line": "A 2020s phone clip" }
  ]
}
```

The built-in `recentPhoneClip` floor already skips phone clips under 10 years old. It moves with the calendar, and it spares files you pick yourself. This rule is different in both ways:

- it is fixed to the 2020s;
- it applies to your own picks too.

A phone clip with no camera date has no `captureYear`, so this rule doesn't fire for it. The built-in rule treats such a clip as recent.

##### More one-liners

- Switch off the phone-clip rule: `"floors": [ { "id": "recentPhoneClip", "enabled": false } ]`
- Allow silent footage (a silent Super 8 transfer, say): `"floors": [ { "id": "noSound", "enabled": false } ]`
- Restore the old "stage ≥ Master means already archived" behaviour (rules v10):
  ```json
  "floors": [ { "id": "stageMeansArchived", "kind": "match", "rejection": "alreadyArchived",
                "when": [ { "field": "archiveStage", "op": "in",
                            "value": ["masterAssigned", "backedUp", "readyForArchive", "archived", "manuallyDeleted", "salvageFailed"] } ] } ]
  ```
  This rule goes at the end of the floors, not second as in v10. The same files are excluded; only the reason shown for a few of them differs.
- Stop 1-star files from counting as vouched: they already don't (the `stars` vouch needs `starRating >= 2`). To lower the bar: `"recommend": { "vouch": [ { "id": "stars", "when": [ { "field": "starRating", "op": ">=", "value": 1 } ] } ] }`

#### Checking what you changed

- At launch, the console says `Archive Angel: using your recommendation rules "<name>" from …`, or `refused … — <every problem>`.
- After each sweep, it logs `Archive Angel Assessment: done: A … · ready N · needs a date M · worth a look K · …`, and (rules v13, unified log, category `archiveAngel`) `coverage: 23 years · 4,812 recordings · deepest backlog 2010 (156 to archive, 27 archived), … · undated 412 to archive`.
- On the first run after a rules-version change, it logs once: `recommendation rules v11 → v12 — before: … now: …`.

#### Rules v12 (2026-09-25) — truthful readiness

Measured on the live catalog that morning and fixed as data (docs/design/archive_angel_wise_design.md §3): the `angelWorkingCopy` safety floor; a footage group's archived original excludes its other members (`archivedCopy`); the `absurdBitrate` and `recentDigitization` class rules and the `yearsAgo` field; `personsearchresults` and `*_compilation_*` in the app-cache tables. Outside the policy, in the ONE date rule (`RecordDateResolver`): a container stamp with no camera behind it (a transcoder's, or of unknown origin) loses to a filename year that disagrees by more than two years — `DickyDonnaDancing1992.mov` stamped 2026-04-03 by Apple ProRes 422 is filed under 1992 (low confidence), not 2026. An inferred date (on-screen dates, speech) still ranks above the filename: one that agrees with the stamp keeps the stamp, one that disagrees wins. Dimensions and rates in a name (`1920x1080`, `2000k`, `2000fps`, `1920p`) are never read as years. The Catalog's Date column shows the same date, and its tooltip says where it came from. A re-encode or export whose footage group's original is archived is excluded with its own reason, "The original of this footage is already in the archive" (the `archivedCopy` safety floor). Every v11 evidence file re-scores.

#### Rules v13 (2026-09-26) — coverage across days and years

docs/design/footage_groups_gap_plan_2026-09-26.md Stage 2, bounded by docs/reviews/codex/codex-review-angel-coverage-2026-09-26.md. The `coverage` section above (one pick per day, `maxPerYearPerBatch`, the `backlogBonus` signal over unique recordings), the evidence file's `catalogRevision` stamp, and two batch-limit reasons. The duration band is unchanged: under 2 min is the `tooShort` floor (60 s for an explicit pick), 2–5 min earns nothing, 5 min–1 h the tiers, and a three-hour capture keeps its +60 — every edge is pinned by `ArchiveAngelDurationBandTests`. Every v12 evidence file re-scores.

#### Rules v14 (2026-09-29) — event labels

Rick approved steps a–c that day. `coverage.eventLabels` (on) and `coverage.birthdayWindowDays` (3), and the *Event labels* section above: holidays, People-tab birthdays and a curated name lexicon widen `onePerEvent`'s event from a day to an occasion. Additive — a v13 `policy.json` loads with both defaults; an unknown key is still named in the log and ignored; a window outside 0…14 refuses the file. The Archive Readiness sheet gains an *Occasion* line. With `eventLabels` off, every key and every pick is rules v13's (`ArchiveAngelEventLabelParityTests`). Every v13 evidence file re-scores.

#### Rules v15 (2026-10-06) — no usable sound, no recommendation

Rick found a video-only DV export with no sound track recommended as Ready (grade A, "Ready — no sound track"). Bad, missing or out-of-sync sound is the one thing that ruins a keeper, so the default floors now include `noSound`, placed right after `pairedHalf`. It refuses:

- a file with no audio stream (video-only, in any container, with or without an extension);
- a sound track Verify Audio found **silent** or **missing** (status `ok`, note `silent audio` / `no audio stream`);
- **damaged** audio (Verify Audio status `damaged`).

The reason reads "No usable sound — no sound track, or the sound is silent or damaged; find its audio and combine first". A correlated video-only half still hears `pairedHalf` ("Half of an A/V pair — combine first"), because that floor runs first. A sound track that has simply not been checked is **not** refused: it stays a candidate, Prepare checks it, and it is never "Ready" until it has been checked ("Needs audio checked"). Informational notes (surround, two live tracks, mono) pass.

`noSound` is not a safety floor. Switching it off (`{ "id": "noSound", "enabled": false }`) is how a policy allows silent footage. It has `explicitPicks: false`, so "Prepare with Archive Angel" on files you selected may still take silent film. It is not star-exempt. Every v14 evidence file re-scores.
