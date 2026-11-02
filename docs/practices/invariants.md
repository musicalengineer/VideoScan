# Invariants: what the nightly adversarial review attacks

Status: built — the nightly adversarial review and `tests/test_invariants_coverage.py` read this file (one file since 2026-11-01; the eight per-area files it replaced are under `docs/archive/practices/invariants/`).

One section per area, in this one file. `tools/adversarial_nightly.py` (through
`tools/invariants.py`) reads it to decide what is in scope each night and to build
the reviewer's brief. Design: `docs/archive/design/nightly_adversarial_review_design_2026-10-01.md` (how to run it: `docs/guides/testing.md` §4 "Runbook").

## Area shape

Each area opens with a marker line, `<!-- area: Archive -->` (the area's name,
used in briefs and fingerprints), then its front matter and body:

    <!-- area: Archive -->
    ---
    tier: data-risk          # or: truth
    paths:
      - VideoScan/VideoScan/Archive/**
      - VideoScan/VideoScanCore/Sources/VideoScanCore/ArchiveFixity.swift
    ---
    # Title
    
    ## Invariants
    1. **ARCH-1** One sentence a reviewer can try to break.
    
    ## Known and accepted (do not report)
    - A deliberate limitation, with who accepted it.

- `tier: data-risk` — a miss can lose or corrupt family media, the archive or
  the family record (docs/guides/developer.md, "Data-risk code"). Reviewed
  at effort `xhigh`.
- `tier: truth` — a miss makes the app say something false (Hallie answers,
  dates, genealogy). Reviewed at effort `high`.
- `paths` are repo-relative globs: `*` stays inside one folder, `**` crosses
  folders. A file may match more than one area; data-risk wins the
  bucket.
- Invariant IDs are stable. Never renumber; retire one by striking it through
  and saying why. Finding fingerprints include the ID.

## The sensor

`tests/test_invariants_coverage.py` fails when a Swift file in a data-risk
folder writes (FileManager mutations, `write(to:`, `CyberBrainWriter`, the
POSIX rename/unlink calls, `AtomicFilePublish`) and no area's
`paths` covers it. Fix it by adding the glob (and an invariant if the file
writes something new) — never by narrowing the sensor.

## Sources

Seeded 2026-10-01 from the codex briefs and review docs in docs/reviews/
(#230 filing, #235 map birth rule, Refile r1–r6, Archive Update, Promote dates
and lock, fixity #1721, rename backups, dates resolver, the 9/28 day bundle),
docs/guides/developer.md and the project's data-safety rules.

## The areas

<!-- area: Archive -->
---
tier: data-risk
paths:
  - VideoScan/VideoScan/Archive/**
  - VideoScan/VideoScanCore/Sources/VideoScanCore/ArchiveFixity.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/ArchiveModels.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/ContentFixity.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/AtomicFilePublish.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/BackupAttestation.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/MediaLedgerEvent.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/LedgerNarrator.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/MachineNote.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/VolumeIdentity.swift
---
# Master Archive (FamilyArchive): promote, 00_Index, Update…, lock, fixity, ledger

## Invariants
1. **ARCH-1** An archived file is never lost or duplicated. A move inside the archive is ONE `renameatx_np(RENAME_EXCL)` between dirfds opened through the O_NOFOLLOW chain — no copy, no unlink. Any failure after the move renames back only the identity-checked original (device+inode+size, before and after); otherwise the outcome is mixedState naming both paths, with the backup kept.
2. **ARCH-2** Nothing in the archive is ever overwritten: every create and rename is exclusive (no-clobber). Each new no-clobber site is inventoried in `ArchiveVolumeProtection`'s `reviewedNoClobberRenames`.
3. **ARCH-3** The 00_Index manifest never disagrees with disk. Rewrites are row-targeted and prepared in memory, then backup → recheck (planned AND unchanged files) → move → publish → rollback, all under `ArchiveIndexLock`. Every index writer and appender (manifest, promote journal, decisions, attestations) holds that lock; on the main thread it is tried once, never slept on.
4. **ARCH-4** A backup is retained unless the error proves it safe to discard. In-progress or unparseable backup folders are never pruned or counted; two operations never share a backup folder; retention never deletes the newest N (DST, mixed legacy/UTC names, clock going backwards).
5. **ARCH-5** Archived means read-only. Promote locks every file; only Update… unlocks → changes → relocks. Background work may add metadata to an archived record but never changes its name or date; archived records donate dates, they never receive them.
6. **ARCH-6** The archived record carries exactly the date Rick chose (never the source's leftover); placement folder, filename prefix, manifest `record_date`/`date_confidence` and the record agree. A machine date never moves a file on its own. Update… changes only what its sheet lists. When the Promote date cannot be written as Rick's date on the record (a typed decade; an Angel machine proposal), the source's own `userDate` that registration carries must agree with the placement at the coarser precision, or Promote refuses before the journal intent (GH #219, `ArchiveDateAgreement`). Verify Archive Copies flags — never rewrites — an archived record whose index, placement and catalog dates disagree.
7. **ARCH-7** Refusals happen before any mutation: target exists, archive offline or read-only, source digest ≠ manifest digest, filing-year guard. A refusal writes zero bytes. A source digest taken from a stored fixity is proven against the source's current bytes before the journal intent (codex 2026-10-02 #1/#4). A change only the engine can see — the source modified during the copy — is rolled back completely: the partial and the folders that run created (empty-only) are removed and its intent line is retracted, or closed `abandoned` when another writer appended after it; nothing that existed before the run is touched. Persistent logs carry refusal codes, operation ids and digest prefixes, never media paths or filenames; the UI keeps the detail (codex 2026-10-02 #7).
8. **ARCH-8** Fixity: a digest binding is counted as stored only after an acknowledged catalog save. A non-regular file (FIFO, socket, device, directory, symlink to one) is never opened for a blocking read or digested. A legacy stamp is untrusted until one full re-read; a missing volume UUID is never a wildcard.
9. **ARCH-9** Outcomes and ledger lines tell the truth: rolledBack, incompleteRecovery and mixedState are distinct; durability unconfirmed is never reported as success; the narrator never claims an undo the event does not carry.
10. **ARCH-10** Promote never claims a file it could not journal: a Busy or failed manifest/journal append means "not archived", and the next run converges.
11. **ARCH-11** Every machine line in a `.notes` file is signed through `MachineNote` and appended; Rick's existing text is never altered or lost.
12. **ARCH-12** The whole FamilyArchive volume is near read-only: no code path offers or performs bulk delete or trash there.
13. **ARCH-13** The archive never holds the same bytes twice (GH #190). Before the journal intent Promote obtains the source's sha256 (a stamp-bound `contentFixity` that `describesFileNow`, else one full read) and refuses — naming the archived file — when the run's index (00_Index manifest + in-root archive-copy `archiveFixity`) or the model's process-wide claims already hold it; the lookup is O(1). Look-up-then-claim is one main-actor step, so two identical files in one batch or in two concurrent jobs cannot both pass. Adoption of an existing file is decided against a digest READ from the source in that run, never a stored fixity (codex 2026-10-02 #1). The engine refuses to publish bytes whose digest differs from the one checked (`expectedSourceSHA`). An unreadable index refuses the run; malformed rows are skipped and reported.

## Known and accepted (do not report)
- Update… has no retry journal: if the catalog save or the ledger line fails after the archive and index are updated, it is logged loudly and reported, and the next scan picks up the new path (Rick, 2026-09-27, "KISS").
- Folders are not locked and the system immutable flag (`schg`) is not used (cut 2026-09-27).
- `ArchiveIndexLock` is a per-volume `flock`; it does not coordinate with a second machine writing the same archive over the network.
- The one-time lock catch-up marker lives beside the catalog (App Support), not on the archive.

<!-- area: ArchiveAngelPromote -->
---
tier: data-risk
paths:
  - VideoScan/VideoScan/ArchiveAngel/Promote/**
  - VideoScan/VideoScan/ArchiveAngel/Review/ArchiveAngelReviewDates.swift
  - VideoScan/VideoScan/ArchiveAngel/Prepare/ArchiveAngelPlan.swift
---
# Archive Angel → Promote hand-off

## Invariants
1. **AAP-1** The Angel proposes; it never promotes, moves, trashes or deletes media on its own. Nothing reaches the archive without Rick's approval in Review, and the hand-off goes through the same Promote engine as the Promote sheet (no parallel copy path).
2. **AAP-2** The date on an approved plan row is exactly the date Promote files under: a typed date survives pre-selection, reload and sibling selection; "Promote undated" stays undated; a copies'-date question must be answered before Promote is enabled.
3. **AAP-3** The fixity check at hand-off reads the source now; a digest that disagrees with the catalog refuses that item and says why.
4. **AAP-4** Family stamps and fact lenders never write a person, place or date onto a record that already holds a stronger (Rick's own) claim, and never onto an archived record.
5. **AAP-5** A refused or failed item is reported per item; the rest of the batch is not silently dropped and nothing is claimed archived that Promote did not journal.

## Known and accepted (do not report)
- Short clips are low-signal and ranked low; that is a ranking choice, not data loss.
- The plan row's `proposedDate`, `inheritedDate` and `dateFromCopiesAnswered` are additive fields; old plans decode with them absent.

<!-- area: Dates -->
---
tier: truth
paths:
  - VideoScan/VideoScanCore/Sources/VideoScanCore/RecordDateResolver.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/RecordDateClaim.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/InferredDateRange.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/VideoRecordUserDate.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/EmbeddedCreationDate.swift
  - VideoScan/VideoScan/Catalog/DateTriangulat*.swift
  - VideoScan/VideoScan/Catalog/DateValidation.swift
  - VideoScan/VideoScan/Catalog/VideoScanModel+DateInference.swift
  - VideoScan/VideoScan/Catalog/CatalogWideMetadataCandidates.swift
---
# Dates: resolving, inferring and sharing a record's date

The resolved date decides where Promote files a video and what the Date column shows. A wrong date misfiles family media.

## Invariants
1. **DATE-1** A user date always wins, at its precision, in every path: resolver, Date column, Promote's date hint, footage-group sharing.
2. **DATE-2** A device stamp (make AND model, or a named action-cam maker) is never demoted as a "software" stamp.
3. **DATE-3** The date catch-up is idempotent and never destroys evidence: a second run changes nothing; clearing an mtime-tier inferred date never clears a user date, an embedded stamp or a date with evidence; a record on an unreachable volume is left untouched.
4. **DATE-4** Footage-group sharing only at `likely` or better; it never propagates a filename year or an export stamp, never overwrites a member's own stronger claim, and a human "not the same" blocks it.
5. **DATE-5** A range resolves to YEAR precision, deterministically, and never to a day; a reversed or empty range never crashes.
6. **DATE-6** Archived records donate dates and never receive them; background inference never writes a date onto an archived record.
7. **DATE-7** Era floors hold: no inferred video date before the era the media type can exist in; a spoken or written year is evidence of a reference, not proof of the recording date.
8. **DATE-8** Every inferred date can say why (its evidence), and the UI shows inferred dates as inferred.

## Known and accepted (do not report)
- Inferred dates for files with no evidence beyond mtime stay empty by design (rules v13).

<!-- area: FamilyTree -->
---
tier: data-risk
paths:
  - VideoScan/VideoScan/FamilyTree/RecordFinderFiling.swift
  - VideoScan/VideoScan/FamilyTree/RecordFinderFoundSheet.swift
  - VideoScan/VideoScan/FamilyTree/ResearchStore.swift
  - VideoScan/VideoScan/FamilyTree/ResearchPerson.swift
  - VideoScan/VideoScan/FamilyTree/ResearchPersonSheet.swift
  - VideoScan/VideoScan/FamilyTree/ResearchAttestation.swift
  - VideoScan/VideoScan/FamilyTree/FamilyAssetStore*.swift
  - VideoScan/VideoScan/FamilyTree/DocumentIngest.swift
  - VideoScan/VideoScan/FamilyTree/VideoScanModel+Documents.swift
  - VideoScan/VideoScan/FamilyTree/VideoScanModel+FamilyAssets.swift
  - VideoScan/VideoScan/FamilyTree/CouplePortrait.swift
  - VideoScan/VideoScan/FamilyTree/FamilyTreeNotes.swift
  - VideoScan/VideoScan/FamilyTree/FamilyTreeLiveModel.swift
  - VideoScan/VideoScan/FamilyTree/FamilyTreeLiveModel+Summaries.swift
  - VideoScan/VideoScan/FamilyTree/FamilyTreeBookmarks.swift
  - VideoScan/VideoScan/FamilyTree/FamilyTreeLineExport.swift
  - VideoScan/VideoScan/FamilyTree/FamilyTreePronunciation.swift
  - VideoScan/VideoScan/FamilyTree/FamilySearchPull*.swift
  - VideoScan/VideoScan/FamilyTree/FamilySearchPersonRefresh*.swift
  - VideoScan/VideoScan/Hallie/HallieTellingMode*.swift
  - VideoScan/VideoScan/Hallie/HallieAppTurnCoordinator+Telling.swift
  - VideoScan/VideoScan/Hallie/HallieAppTurnCoordinator+Pronunciation.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/CyberBrainWriter*.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/CyberBrainCorrections.swift
---
# Family Tree: Record Finder filing, research dossiers, documents, CyberBrain writes, FamilySearch pull

FT-1..FT-7 are the #230 Record Finder filing brief's invariants, verbatim in substance.

## Invariants
1. **FT-1** Nothing is written before every refusal check passes; `.refused` means zero bytes written anywhere.
2. **FT-2** No existing file is ever overwritten; a duplicate SHA-256 is detected across every folder the person has.
3. **FT-3** No dossier writer saves a stale copy: a Research-pane edit (verdict / lore / tell / run) and a concurrent filing both survive, in either order. The same holds for two panes on one person and for rollback (it restores only what this filing changed).
4. **FT-4** Undo reverts only this filing's finding from what is on disk now; `dossier.json` is retired (to `research/.trash`, never deleted) only if this filing created it and it is otherwise empty.
5. **FT-5** CyberBrain is written only when the user ticked "read" and there is a real transcription or lore — never the placeholder, never twice for the same passage. Re-attach after an inspector Remove keeps verdict/told state and does not tell Hallie again. Concurrent CyberBrain writers never lose a passage whose receipt was returned.
6. **FT-6** A rollback leaves the document in `Documents/.trash` with its row gone, and the reported outcome (refused / rolledBack / filed) matches what is on disk.
7. **FT-7** Logs (filer and document store) carry no person name, URL or transcription.
8. **FT-8** A FamilySearch pull or person refresh replaces the tree on disk only with a complete, validated download; the previous tree survives a failed, partial or empty pull.
9. **FT-9** Rick's GEDCOM files are never edited by the app; corrections and identity rulings are data beside them.
10. **FT-10** A sidecar/list the app cannot read is never overwritten with an empty or default one; older builds can still read every list a newer build writes.
11. **FT-11** Private by default: DNA documents stay private unless Rick changes them; nothing about living people leaves the machine.

## Known and accepted (do not report)
- The per-key dossier lock is in-process only; two app processes are not coordinated.
- The lock table grows by one entry per researched person per session.
- A downgrade to an older build cannot decode new `ResearchSourceKind` cases (documented; the kind is written as Other + category for legacy readers).

<!-- area: Genealogy -->
---
tier: truth
paths:
  - VideoScan/VideoScanCore/Sources/VideoScanCore/Gedcom*.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/*Kinship*.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/LineageTrail.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/LifeAndTimes/**
  - VideoScan/VideoScanCore/Sources/VideoScanCore/FamilyMap/**
  - VideoScan/VideoScanCore/Sources/VideoScanCore/TreeStatistics.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/TreeLineStatistics.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/TreeIntegrityCheck.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/FamilyTreeDuplicates.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/FamilyIdentityDecisions.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/USPlaceNames.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/USStateCodes.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/BirthplaceClassifier*.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/RollCall.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/TreeWalkDate.swift
  - VideoScan/VideoScan/FamilyTree/FamilyKinship*.swift
  - VideoScan/VideoScan/FamilyTree/FamilyMapModel.swift
  - VideoScan/VideoScan/FamilyTree/LifeStatus.swift
  - VideoScan/VideoScan/FamilyTree/FamilyTreeRollCall.swift
---
# Genealogy: GEDCOM, kinship, lineage, places, life and times

## Invariants
1. **GEN-1** A relationship name is computed from a real path in the graph — never guessed. Half, step, in-law and "removed" are distinguished; no path or an ambiguous one → abstain.
2. **GEN-2** GEDCOM is read as written: notes verbatim, ids keep their at-signs, nothing invented while parsing; the app never edits the GEDCOM file.
3. **GEN-3** Places: an explicit country wins; old state abbreviations and historic names resolve correctly (New South Wales = Australia; Down → Northern Ireland); an ambiguous place is left unplaced, never misplaced.
4. **GEN-4** The family map places a person from a note only when the note opens with a run of names that are all that person's own (canonical or alias, at least one given name) followed by "was born" / ", born" (#235).
5. **GEN-5** Identity rulings and multiple parent families are honoured as recorded; the code never silently picks one family when a ruling is open.
6. **GEN-6** Date arithmetic: no negative ages, dual years kept, about/before/after qualifiers preserved; a census query never treats a given name as a surname.
7. **GEN-7** Roll Call and other family-facing lists never show a living person; "living" is decided conservatively (no death record and plausibly alive → living).
8. **GEN-8** Statistics and ancestor counts abstain on a family-line scope or a relative clause they cannot evaluate.

## Known and accepted (do not report)
- Notes that do not open with the person's own name ("Born in Cork.", "She was born in Cork.") are accepted false negatives for the map (#235).
- The GEDCOM 200k-person performance ceiling can flake under machine load; it passes alone.

<!-- area: Hallie -->
---
tier: truth
paths:
  - VideoScan/VideoScan/Hallie/HallieTurnExecutor*.swift
  - VideoScan/VideoScan/Hallie/Archivist*Executor*.swift
  - VideoScan/VideoScan/Hallie/*Answer*.swift
  - VideoScan/VideoScan/Hallie/HallieLineage*.swift
  - VideoScan/VideoScan/Hallie/HallieAncestorStatistics*.swift
  - VideoScan/VideoScan/Hallie/HallieTreeStatistics*.swift
  - VideoScan/VideoScan/Hallie/HallieCompositionVerifier.swift
  - VideoScan/VideoScan/Hallie/HallieResponseCommit.swift
  - VideoScan/VideoScan/Hallie/HallieAppTurnCoordinator.swift
  - VideoScan/VideoScan/Hallie/HallieAppTurnCoordinator+TurnMemo.swift
  - VideoScan/VideoScan/Hallie/HallieVitalDates.swift
  - VideoScan/VideoScan/Hallie/HallieMarriageDate.swift
  - VideoScan/VideoScan/Hallie/HallieServiceStory.swift
  - VideoScan/VideoScan/Hallie/HallieClarification*.swift
  - VideoScan/VideoScan/Hallie/HallieGeneralAnswerBoundary.swift
  - VideoScan/VideoScan/Hallie/LLM/**
---
# Hallie: answers and their truth

## Invariants
1. **HAL-1** Every family fact in an answer is grounded: composed in Swift from catalog / tree / CyberBrain data that carries a citation. The LLM only translates questions and phrases a verified plan; the composition verifier rejects any name, date, place or relation not in the plan.
2. **HAL-2** Abstain over guess: an unparsed constraint (side, branch, family-line scope, relative clause, qualifier) gives a clarification or an abstention, never a broader answer presented as the narrow one.
3. **HAL-3** The right person: a name resolves through People ↔ CyberBrain aliases and identity rulings; an ambiguous name asks "which one", never silently takes the first match.
4. **HAL-4** Within a turn no answer is built from a read older than a write Hallie made in that same turn, and the next turn always reads fresh.
5. **HAL-5** Ages and dates are stated at their precision: no negative or "about 0" ages; dual years and about/before/after qualifiers survive; a living person's age is not computed from a guess.
6. **HAL-6** Catalog answers (counts, superlatives, "show me") count the same records the Catalog would show, and a decline says it is declining rather than inventing.
7. **HAL-7** General knowledge from the LLM is labelled as such and never mixed into a family-fact sentence.

## Known and accepted (do not report)
- Rare given names or nicknames with no alias on file are declined ("I don't know who that is"); adding aliases is a data task.
- Phrasing variety comes from the LLM; only the facts are checked.

<!-- area: MediaOps -->
---
tier: data-risk
paths:
  - VideoScan/VideoScan/MediaOps/DeleteDuplicates*.swift
  - VideoScan/VideoScan/MediaOps/DuplicateKeeperPolicy.swift
  - VideoScan/VideoScan/MediaOps/SignatureVerification.swift
  - VideoScan/VideoScan/MediaOps/SignatureConcurrencyPlan.swift
  - VideoScan/VideoScan/MediaOps/JunkDeleteAction.swift
  - VideoScan/VideoScan/MediaOps/VideoScanModel+JunkDelete.swift
  - VideoScan/VideoScan/MediaOps/VideoScanModel+TrashSelection.swift
  - VideoScan/VideoScan/MediaOps/VideoScanModel+SoftDelete.swift
  - VideoScan/VideoScan/MediaOps/VideoScanModel+Prune*.swift
  - VideoScan/VideoScan/MediaOps/PruneApplyJob.swift
  - VideoScan/VideoScan/MediaOps/*Purge.swift
  - VideoScan/VideoScan/MediaOps/VideoScanModel+*Purge.swift
  - VideoScan/VideoScan/MediaOps/Relocate*.swift
  - VideoScan/VideoScan/MediaOps/VideoScanModel+Relocate*.swift
  - VideoScan/VideoScan/MediaOps/VideoScanModel+RepairLifecycle.swift
  - VideoScan/VideoScan/MediaOps/RescueFileCopier.swift
  - VideoScan/VideoScan/MediaOps/PartialFileNaming.swift
  - VideoScan/VideoScan/MediaOps/DerivedFileNaming.swift
  - VideoScan/VideoScan/MediaOps/DerivativeOutputPublish.swift
  - VideoScan/VideoScan/MediaOps/CombineOutputPublish.swift
  - VideoScan/VideoScan/MediaOps/MediaTrash.swift
  - VideoScan/VideoScan/MediaOps/DeletionAudit.swift
  - VideoScan/VideoScan/MediaOps/FullHashBackfillResume.swift
  - VideoScan/VideoScan/MediaOps/CatalogAudit*.swift
  - VideoScan/VideoScan/MediaOps/VideoScanModel+CatalogAudit.swift
  - VideoScan/VideoScan/Integrity/*.swift
  - VideoScan/VideoScan/MediaOps/ImportToSQLite*.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/Import/CatalogImporter*.swift
  - VideoScan/VideoScan/App/CatalogAuditCLI.swift
  - VideoScan/VideoScan/MediaOps/CombineEngine.swift
  - VideoScan/VideoScan/MediaOps/CombineVerifier.swift
  - VideoScan/VideoScan/MediaOps/VideoScanModel+Combine*.swift
  - VideoScan/VideoScan/MediaOps/TranscodeJob*.swift
  - VideoScan/VideoScan/MediaOps/TrimJob.swift
  - VideoScan/VideoScan/MediaOps/TrimEngine.swift
  - VideoScan/VideoScan/MediaOps/ReformatJob.swift
  - VideoScan/VideoScan/MediaOps/RebuildAudioJob.swift
  - VideoScan/VideoScan/MediaOps/BalanceAudioJob.swift
  - VideoScan/VideoScan/MediaOps/CleanupJob.swift
  - VideoScan/VideoScan/MediaOps/CleanupFFmpegEngine.swift
  - VideoScan/VideoScan/MediaOps/FootageSpectrum*.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/PrunePlan.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/CleanupEngine.swift
---
# Media File Operations: delete, prune, purge, relocate, rescue, and every job that writes media

## Invariants
1. **MOPS-1** Removal safety: a file is moved to the Trash only after proving, at the moment of the move, that a surviving copy exists (sibling proof / signature re-read now, not a cached verdict). When in doubt, refuse. Trash only, never permanent (Rick 2026-10-09): a Trash the volume refuses is a hold, never an unlink.
2. **MOPS-2** AT THE FINAL VERDICT IMMEDIATELY BEFORE A REMOVAL, NOTHING COMES FROM A CACHE: which physical device each counted copy is on (`DuplicateDrives.liveIdentityFresh` through `DeletionTierFacts.recheck`), the Archive Angel's holds (`inFlightRecordIDsFresh` — every plan file read — plus the model's live sets) the Read-only marks (the marks as they are now, turned into a protection there and then) and the Master Archive rule (the current designation, turned into a protection there and then — `removalBoundaryArchiveCheck`) are each read fresh at that point; with each counted copy's stamp and the model's live Angel state that makes six, all fresh; the model's part of them (holds — the A/V pairing included — marks and designation) comes over in ONE synchronous main-actor hop (`DeleteDuplicatesJob.removalBoundary`). TRASH ONLY (Rick 2026-10-09): every removal is a move to the drive's Trash; nothing in Delete Duplicates unlinks a duplicate, a recorded `.permanent` (an older plan) is executed as the Trash, and a Trash the drive refuses is a hold with the file back at its path (`DeleteDuplicatesTrashOnlyTests`, source sensor included). FAIL CLOSED ON UNCERTAINTY: nothing the final verdict cannot read lets a file go — an Angel buffer that cannot be listed, a `batch-` folder with no plan.json yet, a plan that does not open or decode (`inFlightRecordIDsFresh` answers ids / uncertain, and uncertain is a hold for that removal); a catalog or model that went away holds; a record that left the catalog is still asked of the Angel's sets by id; a volume whose physical device cannot be established never adds a drive. A check captured earlier (the copy's turn) may still be asked first, but only to refuse — it is never what lets a file go. Caches (`liveIdentityCached`, `inFlightRecordIDsCached`, the model's snapshots) serve only forecasts, the Storage / steward displays and the per-turn pre-checks, which are advisory — the final verdict is the authority. KEEP ONE (Rick 2026-10-09): duplicate delete needs ONE verified copy to remain — the keeper, proven at the move (read in full or its stamp-bound fixity, digest matched, not an alias of the target) — `DeletionTierDecision.minimumForTrash == 1`; copy counts only decide which rows are PRE-SELECTED (three or more copies), never whether a copy is identical. The family's other copies, and the drives below, are still counted for the row's words and the ledger. A "drive" is a PHYSICAL DEVICE, one key per device (`DuplicateDrives`: the DiskArbitration device path of the volume the copy was stat'ed on — never the path's spelling, never the volume). Two volumes of one device — two APFS volumes in one container, two partitions of one disk, two volumes of one RAID — are ONE drive. WHAT COUNTS as a drive: a physical device holding a local volume, and a network volume (one drive per server + share). WHAT NEVER DOES: a mounted disk image (.dmg, .sparsebundle, a RAM disk — its backing file may sit on the very drive the other copies are on) and a volume whose physical device cannot be established; a copy there still counts as a copy. SURVIVORS (S1, codex #258 round 5): a row planned as a target of THIS run is NEVER counted as a surviving copy for another row of the run — whatever became of it (removed, left alone by the tier, refused, held, failed, put back; a new plan or an old one), neither as a sibling nor as an archive copy (`duplicateSurvivorStandingRule`, `deletionTierCandidates`). Survivors are only the keeper and copies that are NOT rows of this run, by the sibling rules; an extra copy on the cleaned drive that is not a row (held, Read only, never planned) does not count either, except one the Master Archive rule protects. This is stricter than main, which also counted rows it had decided and kept. `DeleteDuplicatesPlan.Entry.notCountedWhy` is the row's reason in words; counting does not depend on it. IDENTITY UNAVAILABLE fails closed: when a file's own volume UUID cannot be read, a Read-only mark carrying a UUID holds it, and a Master Archive designated with a UUID makes it unprovable — unless the file is provably elsewhere (the boot disk, a network share, or, for the archive found mounted by its UUID, another mount). The Angel's buffer is "never made" only when the drive it lives on is mounted; a `batch-` symlink is uncertain. Known limit — only what cannot be seen: a hardware RAID presents as ONE device and counts as one drive (its internal redundancy is NOT a second drive); two disks in one enclosure that present as two separate devices count as two; two network shares backed by one server disk count as two (the share is all that can be seen); a volume spread over SEVERAL physical stores (Fusion Drive, CoreStorage, a multi-store APFS container) is keyed by the ONE store DiskArbitration reports — no reliable signal for "more than one store" was found in its description, so two such volumes sharing a store other than the reported one could count as two. A keeper is never elected on a retired, offline or scratch volume; no group ever loses every member, whatever the order or concurrency of the job.
3. **MOPS-3** No MediaOps lane (delete, prune, purge, relocate, cleanup) deletes, moves or trashes anything on the FamilyArchive volume or inside the Master Archive tree.
4. **MOPS-4** Outputs never clobber: a derivative, combine, transcode, trim, reformat, rebuild or rescue output is written under a partial name and published with an exclusive create/rename. Only the job's own partial file may be removed or trashed.
5. **MOPS-5** Source media is never modified by a job that produces an output. Combine (A/V stitch) muxes with `-c copy` only; no re-encode; the output is verified (streams, duration) before it is announced.
6. **MOPS-6** Relocate is copy → verify (size + digest) → only then remove the source. A failed or interrupted verify leaves the source untouched, and the catalog record follows only a verified copy; reconcile never points a record at an unverified file.
7. **MOPS-7** Catalog and disk agree after every item: a record is marked deleted, trashed or moved only after the filesystem call succeeded. Stop and Pause leave a resumable state, never a half-applied item.
8. **MOPS-8** A path used for a destructive call comes from the catalog record and stays inside its volume root; symlinks are not followed onto another volume; a renamed or replaced file (identity changed since planning) is refused.
9. **MOPS-9** Every destructive lane logs START, a result line per item and OUTCOME through the one sink (console, catalog.log, videoscan.log) and shows as an MFO row; nothing destructive runs silently.
10. **MOPS-10** Compare Footage (Footage Spectrum) only READS media: it writes nothing but its own run folder and extraction cache under `~/Library/Caches/VideoScan/spectrum`, and its one deletion is the 14-day prune of UUID-named run folders directly under `<root>/runs` (canonical parent re-checked) — never the cache, never anything else.
11. **MOPS-11** `MediaTrash.move` is THE one call that hands a catalog media file to the Trash (GH #143): it calls `FileManager.trashItem` and returns where macOS put the file; a volume with no usable Trash throws and the file stays where it was — no fallback to any other kind of removal. Under the test host it moves into a per-process temp Trash with no-clobber naming; nothing else in it writes.
12. **MOPS-12** The deletion receipt (`DeletionAudit`) writes ONLY its own per-run CSV under its receipts folder: created exclusively (a name clash gets `_2`, never an overwrite), rows appended as they happen, the final rewrite atomic. It never touches media, the catalog or the ledger, and a receipt that cannot be written never stops or changes a removal.
13. **MOPS-13** The full-hash backfill marker (`FullHashBackfillResume`) writes ONLY `fullhash-backfill.json` beside catalog.json, through `AtomicFilePublish`; it records that a run started or finished and nothing else. A missing, damaged or unfinished marker changes a menu title and a log line — it never starts work and never alters a record.
14. **MOPS-14** Audit Catalog tier 0 (`CatalogAuditJob`, design: docs/archive/design/catalog_status_freshness_2026_10_16.md §6) only STATS media — nothing on media is opened, moved, renamed, deleted or written, and the archive volume is never touched — and it marks a row Missing ONLY on evidence read at the moment of marking, THROUGH a read-only directory handle, in a folder on the volume (persistent UUID) and, when the stamp carries one, the physical device that the row's `auditSeenOn` stamp says the file was last seen on, with no symlink anywhere in the path and the handle proven to still name its path; every other answer is "could not check" or "needs a decision", never a mark. Its only writes are the removal marker (compare-and-set through `VideoScanModel.applyCatalogAudit`), the where-seen stamp, catalog saves, log lines and `catalog-audit.json`; an unacknowledged save undoes that batch's marks by value and revision and fails the run. The decision table, the mechanics and the pinning tests follow (the pre-2026-11-01 paragraph, verbatim: docs/archive/practices/invariants_MOPS-14_MOPS-16_2026_11_01.md).

    **Decision table — what the audit sees, what it may do, and its words.** The first pass is one `stat(2)` per media path; its ENOENT decides nothing. Any "could not check" or "needs a decision" row refuses the mark; only the **marked** row writes a Missing marker, and only when none of the refusing rows applies.

    | Observed (read fresh, at the moment of marking) | Result | Words / rule |
    |---|---|---|
    | the lane root is not mounted (kernel mount table, read after the stat, no cache) | not asked | the cheap skip; nothing is inferred from it |
    | the row has no `auditSeenOn` stamp | needs a decision, NEVER marked | `neverSeenByAnAudit`: "not at its path, and no audit has seen it before — Fix Links decides" |
    | a symlink in ANY existing component of the path (lexical `lstat` walk; an intermediate one too, `/var` → `/private/var`; test sandboxes use a realpath'd root), ELOOP, or a folder that will not open and that `fstatat` (link not followed) shows to be a link (Darwin reports `O_NOFOLLOW \| O_DIRECTORY` on a link as ENOTDIR) | could not check | "a link in the path, not provable" (D6) |
    | the handle no longer names its path — `fstat(fd)` dev+ino ≠ `lstat(path)` dev+ino, or not a directory — after the open (D9) or after an ENOENT / ENOTDIR on a folder or the name | could not check | "the folder changed under the audit" |
    | the handle's volume UUID ≠ the stamp's volume UUID (an unmounted drive's stub folder, a nested volume that left — its stub belongs to the outer volume —, a relocated home, a volume with no UUID) | could not check | "the folder is on a different volume than the file was last seen on (drive not connected?)" — the ONE proof rule (D5) |
    | the stamp carries a device key and the handle's device key differs (a clone or restored image mounted at the path while the original is away), or DiskArbitration cannot describe the handle's drive | could not check | "a clone? not marked" (D8) |
    | the stamp carries no device key (a share, a disk image, an older stamp) | proven by volume UUID alone | a share's clone is the share |
    | a file where a folder was | could not check | — |
    | any errno but ENOENT / ENOTDIR | could not check | — |
    | the name is there | present | a link where the file was is "not a regular file", never gone |
    | the size differs | reported "changed", NOT marked | — |
    | an archived copy whose file is gone | reported, NOT marked | — |
    | a live, non-archived row (read from the LIVE record) proven gone by all of the above | **marked** | `stampRemoval(.missing, reason .missingAtAudit)` |
    | a Missing row whose file is back at its path | **cleared** | `clearRemoval`, which validates the file is back first |

    **Mechanics.**
    - *The one declared exception to "nothing opened"* (codex r2 2026-10-16 F2): a DIRECTORY handle, read-only (`open` / `openat` with `O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`), never a media file, never for writing; read through it with `fstatfs` + the volume's persistent UUID via `fgetattrlist ATTR_VOL_UUID` (`VolumeIdentity`), `fstatat` with `AT_SYMLINK_NOFOLLOW`, `fstat`, plus `lstat` on pathname components for the two D6 checks. These calls live in `CatalogAuditPlan.swift` (`CatalogAuditDirectoryWalk`) and nowhere else in the audit; every handle is closed on every path. A handle is opened at most twice per row: in the first pass for a file the stat found PRESENT (one handle per folder; the identity and each name through it — the where-seen stamp), and at the mark for a gone answer.
    - *The walk, in order* (r2 F2, r3 F2 = D6; D9 = codex r4 F2, because `O_NOFOLLOW` guards only the LAST component of the pathname given to the open): (1) the lexical `lstat` walk over every existing component; (2) open the nearest existing ancestor folder, walking up by opening, `O_NOFOLLOW` on each step's last component; (3) the lexical `lstat` walk AGAIN, and the handle must name its path (`fstat(fd)` dev+ino == `lstat(path)` dev+ino, a directory) before anything is read through it — in the proof AND in the first pass's stamp acquisition (`seenOn`: a link substituted between the walk and the open, or the folder replaced between the open and the name read → NO stamp, the row's old stamp untouched); (4) `openat` each remaining folder one at a time (closing the previous handle) and `fstatat` the name.
    - *The stamp* (`VideoRecord.auditSeenOn`): volume UUID, what was mounted there, when, and (D8) the physical device key `AuditSeenOn.deviceKey` = `DuplicateDrives.physicalDeviceKey` — the same DiskArbitration device-path digest the Delete Duplicates two-drives rule compares — asked for the handle's `f_mntfromname`; nil for a network share or a disk image; a LOCAL device DiskArbitration cannot describe gets NO stamp at all (codex r5 2026-10-16 P1), because a key-less stamp would later prove by volume UUID alone. The one DiskArbitration call lives in `DuplicateDrives` (DeleteDuplicatesDrives.swift), never in an audit source. The audit writes the stamp for every file it finds (present, changed, came back); clone, rescan preservation and the catalog file carry it. It lives in exactly one place in the model half and is not a mark: no undo bookkeeping, no revision, flushed with the marks on the 60 s clock, at lane end and at run end, never a save per row; a save that is not acknowledged simply loses the stamps. D10: a stamp means "this path's folder, on this volume" — ANY change of `VideoRecord.fullPath` (Relocate, a source-side move, a rename, a volume-rename migration) clears it in the one setter (codex r5 P2), and the next audit stamps the new place and marks nothing there. The r2 lane-root identity and the "/" stub rule are superseded and removed (codex r3 2026-10-16 F1, D5).
    - *Compare-and-set*: `applyCatalogAudit` writes only if the row's id AND a snapshot of the fields that matter still hold as planned — path, size, marker, lifecycle stage, archive stage and fixity presence, derivation kind, supersession, hash time, mtime, the stamp (r2 F3, r3 D5).
    - *Rollback by value and revision* (r2 F4): `VideoRecord.removalRevision` is bumped ONLY by the engine (`stampRemoval` / `clearRemoval` / `revertRemoval`) when the marker's value changes; each audit mark records the revision its write produced; an unacknowledged save undoes that batch's marks on the current row instance only where the row still carries exactly the audit's marker AT that revision — an equal value written since by another door (nil → Trash → Put Back → Restore → nil, or an identical marker reinstated) has a higher revision and is left alone ("changed by another door"); only the marker and the mirrors the write itself moved go back. Accepted: an identical re-stamp by another door leaves the revision unchanged, so the rollback can clear that identical marker — it is the audit's own value.
    - *Outcome*: failed > stopped > completed, so Stop followed by an unacknowledged save is "failed" (CLI exit 1, run marker failed, row "Failed — marks undone"), never "stopped"; a stopped run says "partial". It never deletes a row and never leaves an unsaved mark.
    - *Rescan preservation* carries `removalRevision` and `auditSeenOn` (r3 F3 = D7): a row with removal history alone stays in the rescan map (`carriesRemovalHistory`).
    - *Headless*: `--audit-catalog` refuses when the VideoScan app is open (one catalog writer) and on a viewer-role Mac.
    - *Declared residual*: a file arriving after the observation, or a folder replaced and replaced BACK between two syscalls (two renames by an outside actor inside that window) — the next run restores it.

    **Pinned by** `CatalogAuditJobSensorTests` (reads the sources: the second look before the one `stampRemoval`, against the live record's stamp; the one-rule guard; the two D6 checks; the D9 post-open binding in the proof and in `seenOn`; the D8 device comparison; no DiskArbitration call in any audit source; no `await` in the model half; no object memento; the handle calls in the plan file only; no superseded rule left; no write / rename / unlink / open-for-writing anywhere in the audit); `OneEngineSensorTests` (the one bumper of the revision); `CatalogAuditProveAtTheMarkTests` and `CatalogAuditRound2Tests` (each case on the real filesystem).
15. **MOPS-15** Verify Catalog (`VerifyCatalogJob`, design: docs/archive/design/integrity_first_2026_10_16.md §2–§5) writes ONLY its report: `integrity-latest.json` and the dated copy `integrity-<ISO date>.json` beside catalog.json, both through `AtomicFilePublish` (`IntegrityReportStore.write`, the one writer). It is READ-ONLY on the catalog and on media: the rows are snapshotted on the main actor into Sendable values (`IntegrityRow`, one O(records) pass), every tier runs off the main actor on that snapshot, no record field is written, the catalog is never saved, no removal marker is touched, no media file is opened — the only reads of files are the audit's marker (`catalog-audit.json`, tier 0) and the streamed SHA-256 of catalog.json itself (tier 5, `CatalogFileHash`: one read-only `FileHandle`, 1 MiB chunks). It checks; it never fixes: every finding is a row in the needs-a-decision bucket for Fix Links / Fingerprint Sound / the person. It never deletes a dated copy (a prune is a delete; the history is bounded by the calendar, not by this code). START, one line per tier and OUTCOME go through the one sink (`verifyCatalogNote`: console + catalog.log, videoscan.log, the unified log); a report that cannot be written is said out loud, OUTCOME is still logged and the row ends Failed with the findings in its detail. `VerifyCatalogSensorTests` reads the sources (no file-moving / -removing / -writing call, no row write, no catalog save, no `Process()`, nothing that opens media; `AtomicFilePublish` only in IntegrityReport.swift, `FileHandle` only in CatalogFileHash.swift).
16. **MOPS-16** Import to SQLite (`ImportToSQLiteJob`, design: docs/archive/design/catalog_sqlite_migration_2026_10_16.md §10c "app wiring"; ONE ACTION VERB, Rick 2026-10-17) — ONE WRITER, ONE GENERATION: from the moment the pre-flight passes until the Core importer returns, every write to catalog.json is HELD under an owner token; inside the hold it runs audit → verify → import in that order at one generation G; it never writes `catalog.sqlite` directly (a commit lands in a staging folder and is published through a gate Stop closes); the JSON catalog is never moved, renamed or deleted; the one deletion is its own dry-run scratch; and a quit during a run never loses a held edit (a checked save, else a recovery copy, else an alert that keeps the app open). The sequence, its interruption branches and the pinning tests follow (the pre-2026-11-01 paragraph, verbatim: docs/archive/practices/invariants_MOPS-14_MOPS-16_2026_11_01.md).

    **The sequence (a run that completes).**
    1. **Refuse before any work** (`ImportToSQLitePreflight`, pure, every refusal listed with its words): unsaved catalog changes; another MFO job running; `catalog.sqlite` already there (commit; even empty). Open Delete Duplicates plans and Archive Angel batches refuse through the importer's gate. While an import is active, the standalone Audit Catalog and Verify Catalog starts refuse ("Import to SQLite is running and runs its own …").
    2. **Take the hold — an atomic admission boundary** (codex 2026-10-17 P2): `CatalogStore.holdWrites(reason:owner:)` (async) sets the hold on the main actor, then waits behind `writeQueue` (serial with saves) and for the main-actor completion of every save admitted before it, so nothing admitted earlier is outstanding when it returns; the START line's generation is read after that drain. The hold is checked in `writePrecondition` before the lock; the owner token is `CatalogWriteHoldOwner`, fresh per job.
    3. **While held**: `saveNow`, `scheduleSave` → `saveAsync` and `saveAcknowledged` all refuse with `.heldByJob(reason)` (journalled like every refusal) — EXCEPT `saveAcknowledged(records:as:)` presenting the holder's token (any other token, or none, is held). Held saves are counted; `hasUnsavedChanges` counts acknowledged saves in flight too.
    4. **Phase 1 — Audit Catalog**: the existing `CatalogAuditJob` (MOPS-14), not added to the center, its saves presenting the token (`writeHoldOwner`); its where-seen stamps and marks are evidence the importer checks (N1). When it ends the store's generation is **G**.
    5. **Phase 2 — Verify Catalog**: the existing `VerifyCatalogJob` (MOPS-15), started only after the audit's finishing second + 1.5 s (`ImportToSQLiteTiming.verifyStartDelay`: the gate refuses an audit that finished in the second Verify started), the wall clock RE-READ after every wait and waited out again on a backward step, bounded (`waitForVerifyStart`, `verifyWaitRounds`; a clock that keeps stepping back refuses with words — codex 2026-10-17 P3). It snapshots catalog.json AS THE AUDIT SAVED IT — decoded read-only off the main actor with `load()`'s own decoder (`CatalogStore.decodeCatalogFile`), refused unless it carries exactly G (`VerifyCatalogJob.snapshotSource = .auditedFile(generation:)`) — never the in-memory rows, so an edit made after the audit's save cannot be certified as G (codex 2026-10-17 P2; the standalone Verify Catalog still snapshots the live rows).
    6. **Phase 3 — the import**: after checking catalog.json's header is still at G, the Core importer. A commit run first MOVES leftovers (every `catalog.sqlite.importing-*`, and companions beside no catalog.sqlite) into one `catalog.sqlite.import-aside-<stamp>/` folder — nothing is deleted; the importer's own existing-target and target-empty checks stand behind step 1. It writes a STAGING folder beside the catalog (`catalog.sqlite.importing-<runID>/`: its own database, WAL, -shm and high-water witnesses), never `catalog.sqlite` itself (THE COMMIT FENCE, codex round 2 P1, by construction).
    7. **Publish**, only when `.imported`, closed, reopened `.readWrite` and verified ok, through the gate Stop closes (`ImportStopFlag.claimPublish` / `raise` under one lock, the importer's `publishPermit`): RENAME_EXCL of the companions (catalog.highwater, catalog.highwater.log, -wal, -shm) first and the database LAST, every target name checked absent first, a failed rename putting back what moved. The WAL travels with the database because the store's close does not fold it in (GRDB closes the writer before its read-only readers).
    8. **Release the hold** (`CatalogStore.releaseWriteHold`); the held saves become ONE catch-up `saveCatalogDebounced()`, so a change made during the run is delayed, never lost.

    **Interruption branches.**
    - *The drain stalls* (step 2; codex 2026-10-17 round 2 P2): `holdWrites(reason:owner:within:)` returns `.writerStalled(heldSaves:)` when an admitted save does not land within `CatalogStore.holdDrainDeadline` (60 s), the hold already given back; the job refuses before phase 1 with "a catalog save did not finish within 60 s — try again" (a save refused meanwhile is caught up).
    - *A phase cannot complete* (steps 4–6): the job stops with that phase's words ("the audit could not complete: …"), nothing is imported, the hold is released.
    - *Stop* (any step): forwarded to the phase job in flight (the audit saves what it marked; Verify ends after its tier) and to the importer's `stopRequested`, asked before the target opens and at each phase boundary of its one transaction; the row ends Stopped (never Done), nothing imported. Pause is not offered.
    - *Quit during a run* (codex 2026-10-17 P1; `applicationShouldTerminate`, `.terminateLater`, both file-operation paths), in this order: (a) Stop the job and await its end, bounded by `ImportToSQLiteQuit.deadline` = 30 s (the importer rolls back, the job releases its hold); (b) past the bound, release the hold by force; (c) ask whether every admitted save drains within `ImportToSQLiteQuit.writerDeadline` (`waitForWriterToDrain`, awaited, the main thread free) — a writer that does not is STALLED and the synchronous save is skipped (it would block the main thread on `writeQueue.sync`); (d) otherwise make the DURABLE `saveNow` of the held edits; (e) a stalled writer or a failed save is followed by a RECOVERY COPY — the in-memory catalog in the store's own payload/encoder, published with AtomicFilePublish (`.fullFsync`) off `writeQueue`, bounded, as `catalog.recovery-<stamp>.json` beside catalog.json (START/OUTCOME through `catalogQuitNote`); (f) `settleAndSave` returns `.saved` / `.recoveryCopy(url)` / `.unsaved(words, changes)` and the delegate replies with it: `.unsaved` raises an alert with the store's words — "Keep VideoScan open" (default → `.terminateCancel`, nothing shut down) or "Quit and lose N unsaved change(s)". A COMMIT that completes after a forced release lands in staging: the outcome is `stopped`, catalog.sqlite never appears, and the quit line says which happened (gate held, or publish already begun). (THE SAVE AT QUIT IS CHECKED, round 2 P1/P2.)
    - *Terminate*: `applicationWillTerminate` Stops a running import, releases a hold still up, then makes the same checked save (`CatalogQuitRecovery.saveAtTermination`, its waits bounded by semaphores) and logs the branch. The quit lines go through the one sink.
    - *Next launch*: says when a recovery copy is beside the catalog (console + catalog.log); nothing merges it.
    - *Stopped / rolled back / failed / abandoned* runs leave only staging (moved aside by the next commit run, step 6).

    **What it writes.** It READS the catalog folder; besides what its audit (MOPS-14) and Verify (MOPS-15) write, at most two things: `catalog.sqlite` beside the catalog (commit mode, by publishing its staging folder; a staging folder or an aside folder of leftovers may remain beside it) and the dry-run marker `import-dryrun.json` (`ImportDryRunMarker`, `AtomicFilePublish`, MOPS-13's shape: a missing, damaged or other-build marker only disables a menu item). The JSON catalog is written only by its own audit's saves — the cutover (F′) is a separate, later act.

    **The dry run** writes no database beside the catalog: the importer runs the identical flow (gate, one transaction, rows, sidecars, comparator) against a database in a scratch folder it owns under the temporary directory and rolls the transaction back by design (`.dryRunPassed`), then removes that folder — the one deletion in this lane, scratch only, never a catalog or media file. The real import is offered in the Catalog menu ONLY when a dry run passed ON THIS BUILD (`ImportBuildIdentity.current` = CFBundleVersion + the image's Mach-O UUID, recorded in the marker beside the catalog, never UserDefaults; the generation no longer gates — the real run re-proves audit + verify + gate + comparator) and after a sheet showing the last dry run's line and saying so, and "the JSON catalog stays as it is; nothing is deleted". START / the phase lines / the importer's lines / OUTCOME go through the one sink (`importToSQLiteNote`: console + catalog.log, videoscan.log, the unified log); the phase jobs log through their own sinks.

    **Pinned by** `ImportToSQLiteSensorTests` (reads the sources: hold with the token before the three phases, release after, no catalog save in the job, the audit's save presents the token, only `saveAcknowledged` presents one, the precondition checks the hold before the lock; and the quit wiring: settle on both `.terminateLater` paths and REPLY with its answer; willTerminate cancels, releases, then the checked save; wait → forced release → drain check → save in that order; the job passes the publish gate); `CatalogImporterStagingTests` (Core: the late COMMIT staying in staging, the next import moving leftovers aside byte-for-byte, an existing target refusing, the published set opening read-write and verifying); `ImportToSQLiteQuitPathTests` (the late-COMMIT quit end to end, a refused save leaving a recovery copy with the edit, both failing → `.terminateCancel`, willTerminate's checked save, the launch notice, the bounded hold and the job's refusal on a stalled writer, the quit skipping its synchronous save behind one); `ImportToSQLiteJobTests` / `ImportToSQLiteHoldTests` / `ImportToSQLitePreflightTests` (an edit made during a held run in catalog.json after a quit — job ended, and past the bound —; Verify's report counting the audited file's rows, not an in-memory addition; a save admitted before the hold landing before it, store and job; an acknowledged save in flight counted unsaved; a backward clock step waited out again, and a clock that keeps stepping back refused; the three phases in order at one generation; a background save in EACH phase held, with the generation and the file's hash moved only by the audit's own save; the owner's save passing and another token held; each refusal; a phase that cannot complete; Stop in each phase → stopped with nothing imported and the hold released; a real import enabled by a this-build dry run at an older generation).

## Known and accepted (do not report)
- A crash can leave a partial-named output behind; partial-file naming and cleanup find it later.
- Duplicate groups that elect a retired drive's copy as Keep strand data offline — a known blocker tracked separately (2026-08-14), not a new finding.
- ffmpeg/ffprobe run through the app's process runner; their presence is checked at launch.

<!-- area: Volumes -->
---
tier: data-risk
paths:
  - VideoScan/VideoScan/Volumes/VideoScanModel+RetireVolume.swift
  - VideoScan/VideoScan/Volumes/VideoScanModel+DeleteScanTarget.swift
  - VideoScan/VideoScan/Volumes/VideoScanModel+ScanMerge*.swift
  - VideoScan/VideoScan/Volumes/VideoScanModel+VolumeLifecycle.swift
  - VideoScan/VideoScan/Volumes/VideoScanModel+VolumeRenameMigration.swift
  - VideoScan/VideoScan/Volumes/VideoScanModel+VolumeRoleMigration.swift
  - VideoScan/VideoScan/Volumes/VolumeCompare.swift
  - VideoScan/VideoScan/Volumes/ScanCheckpoint.swift
  - VideoScan/VideoScan/Volumes/ScanJobsStorage.swift
  - VideoScan/VideoScan/Volumes/DiscoveryAudit.swift
---
# Volumes: retiring a volume, deleting a scan target, scan merge, migrations, compare/rescue

## Invariants
1. **VOL-1** Retire Volume and Delete Scan Target remove catalog records only — never a file on any volume.
2. **VOL-2** Only the named volume's or target's records are removed. Matching is by volume identity (UUID) or an exact root path with a separator — never a bare prefix (`/Volumes/X` must not match `/Volumes/X 1` or `/Volumes/XY`).
3. **VOL-3** A whole-volume removal logs START/OUTCOME with counts and leaves the catalog recoverable (snapshot or undo) until the save is acknowledged.
4. **VOL-4** A scan merge never drops the records of files that are merely unreachable (offline ≠ deleted); a moved file re-attaches to its record by identity and is never duplicated; user data on a record (dates, notes, stars, dispositions) survives a re-scan.
5. **VOL-5** Rename and role migrations are idempotent (running twice changes nothing the second time) and never change a record's identity or its user data.
6. **VOL-6** Scan state and reports (checkpoints, job storage, discovery audits, CSV exports) are written atomically to App Support or Logs, never onto a scanned volume.
7. **VOL-7** Compare's rescue copy never overwrites an existing file and never modifies the source.

## Known and accepted (do not report)
- A checkpoint lost in a crash costs a re-scan, not data.
- Volume roles (MASTER / new / scratch / retired) are Rick's labels; the app does not infer them.
