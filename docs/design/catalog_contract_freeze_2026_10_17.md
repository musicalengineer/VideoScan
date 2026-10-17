# Catalog contract freeze — step B (2026-10-17)

Status: DESIGN, read-only. Brief: `docs/briefs/cloud/CONTRACT_FREEZE.md`. Plan: `catalog_sqlite_migration_2026_10_16.md`
§10 (v3: verify once → import the verified rows → rescan by digest → cutover); `integrity_first_2026_10_16.md`
§2–§3a. Schema: `catalog_sqlite_schema_v1.sql`. GH #328. Read from source (no Swift toolchain); every writer is a
grep-and-read citation.

**Revision 2.** Closed codex's 12 first-pass findings
(`docs/reviews/codex/codex-review-contract-freeze-sqlite-schema-v1-step-b-2026-10-17.md`) per
`docs/briefs/cloud/CONTRACT_FREEZE_R2.md`; changes carry `<!-- F<N> -->`.
**Revision 3 (schema v1.2).** Closes the closing pass's 6
(`docs/reviews/codex/codex-review-contract-freeze-r2-closing-pass-2026-10-17.md`): F5, F8, F9 reopened
(`<!-- F<N>r3 -->`) and new N1, N2, N3 (`<!-- N<N> -->`), per `docs/briefs/cloud/CONTRACT_FREEZE_R3.md`.
Reproductions: `sqlite3 :memory: < docs/design/catalog_sqlite_schema_v1_checks.sql` from the repo root. Run on
sqlite3 3.45.1: F1–F12, D530, F5r3, F8r3, F9r3, N1, N2, N3 print `ok`, `integrity_check: ok`,
`all checks ok (76 assertions)`; 56 statements are expected refusals, each announced. Two rules run through both revisions:
**nothing the JSON carried is merged away**: every imported occurrence is a row keyed by
`(import_run, source_ordinal)`, and the per-content tables hold only the display choice.
And **the importer and the rescan never promote evidence into identity**: no `lstat` verdict, no sampled hash and no
digest key counts as proof that a derived value describes the bytes. <!-- F1 F2 F4 F6 F7 F9 -->

**Path shorthand.** `A/` = `VideoScan/VideoScan/` (app), `C/` = `VideoScan/VideoScanCore/Sources/VideoScanCore/`.
Repeated files: **PR** `C/VideoRecord+ProbeResult.swift` (`apply(ProbeResult)` :122) · **PO**
`C/VideoRecord+ProbeOutcome.swift` (`apply(ProbeOutcome)` :126, the scan drain, called from
`A/Media/VideoScanModel+ProbeEngine.swift:386`, Promote `A/Archive/PromoteToArchiveJob+Steps.swift:567`, moved-file
adopt `A/Volumes/VideoScanModel+ScanMergeMoveIdentity.swift:555`) · **CS** `C/VideoRecord+CombinedRecordSpec.swift`
(Combine, :100) · **MA** `A/Archive/VideoScanModel+MasterArchive.swift` · **RM**
`A/MediaOps/VideoScanModel+RemovalMarker.swift` · **RL** `A/MediaOps/VideoScanModel+RepairLifecycle.swift` · **DI**
`A/Catalog/VideoScanModel+DateInference.swift` · **DS** `A/People/VideoScanModel+Dossier.swift` · **DP**
`A/People/VideoScanModel+DossierPropagation.swift` · **DD** `A/MediaOps/DuplicateDetector.swift` · **DU**
`A/MediaOps/VideoScanModel+Duplicates.swift` · **AB** `A/Media/VideoScanModel+AvidBins.swift` · **DE**
`A/MediaOps/VideoScanModel+DuplicateEnrichment.swift` · **EB** `A/Media/VideoScanModel+EmbeddedDateBackfill.swift` ·
**RLc** `A/MediaOps/VideoScanModel+Relocate.swift` · **PT** `A/People/VideoScanModel+PeopleTags.swift` · **CM**
`A/MediaOps/CheckMedia/CheckMediaJob.swift`.
Two copiers touch nearly every field and are not repeated per row: **CLONE** `snapshotClone()`
`C/VideoRecord+Clone.swift:43` (every persisted field except `archivedAt`; `pairedWith` is rewired by
`A/Catalog/CatalogStore.swift:1240`), and **R** = carried by rescan preservation
`A/Catalog/VideoScanModel+RescanPreservation.swift` (capture :337–385, restore `apply(to:)` :439–492). A field
WITHOUT **R** is lost or recomputed on a rescan today.

## a. Field inventory — `VideoRecord` (129 JSON keys)

Source of truth: `CodingKeys` `C/VideoRecord+Codable.swift:34–102` (129 cases); decoder `C/VideoRecord.swift:756–972`;
encoder `C/VideoRecordDTO.swift:321ff`. Non-persisted stored state, out of the contract: `pairedWith` (object ref;
persisted as `pairedWithID`), `wasCacheHit` (:175), `displacedStampMemo` (:550), `removedSince` (:407, cache of
`removal.since`).

**JSON versions v1–v6** (`A/Catalog/CatalogStore.swift:55–78`; `currentVersion = 6` :79). No version is a
record-level gate: v1→v2 adds the header `savedFromHost`; v3 `suspectedPeople`; v4 the three `sceneCaption*`; v5
`originalFullPath`/`originVolume` + two `ArchiveStage` cases; v6 no record change. Every later field is additive
with `decodeIfPresent` defaults; the only semantic migration is `RemovalMarker.migrated` (`C/RemovalMarker.swift:142`)
mapping `purgedAt`+stage onto a marker. **So ONE importer reading the Swift decoder's shape covers v1–v6** (header:
absent `version` → 1, absent `generation` → 0, `CatalogStore.swift:119–120`); per-version fixtures still prove it
(§9.8). A version > 6 refuses (`CatalogStore.swift:639`).

**Precision / equivalence contract.** Dates: whole seconds (`JSONEncoder .iso8601`, `CatalogStore.swift:1322`) →
INTEGER unix seconds, lossless. `inferredDateConfidence` is `Float` → REAL, compared as Float32. Absent ≡ default
for every key marked N or P below (that is how the DTO writes them). Array order is kept where it carries meaning
(captions `seq`); set-like arrays (people, tags) compare as sets. Digests compare lowercase.

Columns: **Enc** A = always encoded · P = encoded when non-nil · N = encoded when non-empty / non-default (all keys
are optional on READ). **Role** D = disk fact (stat / ffprobe / container tag) · S = derived stamp (*bound* = names
the content or stat it describes; *unbound* = does not) · C = curated by Rick · B = bookkeeping / state machine ·
L = lineage / relation · V = display copy of another field. **Fate**: `col` = column of `files` · `X` =
`files.probe_extra` JSON (by DTO key) · `T:name` = table · drop.

| # | Field (JSON key) | Swift type | Enc | Role | Writers (file:line) | Fate |
|---|---|---|---|---|---|---|
| 1 | id | UUID (`let`) | A | B (PK) | set once at construction `C/VideoRecord.swift:61,745`; decoder | col `files.id` |
| 2 | filename | String | A | D | PO:127; rename `A/Catalog/VideoScanModel+Rename.swift:315`; `A/Archive/VideoScanModel+ArchiveUpdate.swift:421`; CS:101 | col |
| 3 | ext | String | A | D | PO:128; CS:102 | col |
| 4 | streamTypeRaw | String (`StreamType` raw) | A | D | PR:140; CS:106 | col `stream_type` CHECK |
| 5 | size | String | A | V | PO:132; CS:109 | drop (display of 6) |
| 6 | sizeBytes | Int64 | A | D | PO:131; CS:108 | col; = `content.byte_count` (trigger) |
| 7 | duration | String | A | V | PR:125; CS:112 | drop |
| 8 | durationSeconds | Double | A | D | PR:124; CS:111 | col `duration_s` |
| 9 | dateCreated | String | A | V | PO:133; CS:131 | drop |
| 10 | dateModified | String | A | V | PO:134; CS:133 | drop |
| 11 | dateCreatedRaw | Date? | P | D (stat birth) | PO:135; CS:130 | col `fs_created_at` |
| 12 | dateModifiedRaw | Date? | P | D (stat mtime) | PO:136; CS:132 | col `fs_modified_at` |
| 13 | container | String | A | D | PR:123; CS:105 | col |
| 14 | videoCodec | String | A | D | PR:130; CS:114 | col |
| 15 | resolution | String | A | D | PR:131; CS:115 | X |
| 16 | frameRate | String | A | D | PR:132; CS:116 | X |
| 17 | videoBitrate | String | A | D | PR:133; CS:117 | X |
| 18 | totalBitrate | String | A | D | PR:126; CS:126 | X |
| 19 | colorSpace | String | A | D | PR:134; CS:118 | X |
| 20 | bitDepth | String | A | D | PR:135; CS:119 | X |
| 21 | scanType | String | A | D | PR:136; CS:120 | X |
| 22 | audioCodec | String | A | D | PR:137; CS:122 | col |
| 23 | audioChannels | String | A | D | PR:138; CS:123 | X |
| 24 | audioSampleRate | String | A | D | PR:139; CS:124 | X |
| 25 | timecode | String | A | D | PR:127 | X |
| 26 | tapeName | String | A | D | PR:128; AB:146 | X |
| 27 | isPlayable | String | A | **unclear** (probe verdict word) | PR:141; CS:127 | X (Q5) |
| 28 | partialMD5 | String | A | S unbound (sampled) | PO:137; RLc:590 | col `partial_md5`, evidence only |
| 29 | contentHash | String (`v1:`) | A | S unbound (sampled) | PO:138; `A/Media/VideoScanModel+ContentHashBackfill.swift:283`; `A/Archive/VideoScanModel+MediaLedger.swift:464` | col `sampled_hash` (NEVER identity, §e) |
| 30 | contentHashAt | Date? | P | S | PO:139; ContentHashBackfill:284; MediaLedger:465 | col `sampled_hash_at` |
| 31 | embeddedCreationDate | Date? | P | D (container tag) | PR:142; EB:224 | col |
| 32 | embeddedCreationSource | String? | P | D | PR:143; EB:225 | col |
| 33 | originMake | String? | P | D | PR:144; EB:232 | X |
| 34 | originModel | String? | P | D | PR:145; EB:233 | X |
| 35 | originEncoder | String? | P | D | PR:146; EB:234 | X |
| 36 | originalFullPath | String? | P | L (provenance, set once) | RLc:395,585; ScanMergeMoveIdentity:558; MA:1286,1412; R:481 | col |
| 37 | originVolume | String? | P | L | RLc:396,586; ScanMergeMoveIdentity:559; MA:1287,1413; R:482 | col |
| 38 | fullPath | String (`didSet` clears 96) | A | D (where) | PO:129; Rename:316; RLc:398,467,588; `A/Volumes/VideoScanModel+VolumeRenameMigration.swift:716`; ArchiveUpdate:420 | col + `volume_uuid`; live UNIQUE |
| 39 | directory | String | A | D | PO:130; RLc:399,468,589; VolumeRenameMigration:717; ArchiveUpdate:422 | col |
| 40 | notes | String | A | B (machine log) | `A/Volumes/ScanEngine.swift:240`; ProbeEngine:699; RLc:400; PT:203; R | col `machine_notes` |
| 41 | userNotes | String | N | C | `A/Catalog/VideoScanModel+WorkflowTags.swift:84`; `A/Catalog/VideoScanModel+NotesRepair.swift:99`; RL:152; R | T:user_notes |
| 42 | tags | [String] | N | C | WorkflowTags:34,60; RL:148; MA:1334; R | T:workflow_tags |
| 43 | avidClipName | String | A | D (.avb bin) | AB:129; DE:71; MA:1345 | X |
| 44 | avidMobID | String | A | D | AB:130; DE:72 | X |
| 45 | avidMaterialUUID | String | A | D | AB:131; DE:73 | X |
| 46 | avidBinFile | String | A | D | AB:132; DE:74 | X |
| 47 | avidMobType | String | A | D | AB:133; DE:75 | X |
| 48 | avidMediaPath | String | A | D | AB:134; DE:76 | X |
| 49 | avidTapeName | String | A | D | AB:135; DE:77; MA:1346 | X |
| 50 | avidEditRate | Double | A | D | AB:136; DE:78 | X |
| 51 | avidTracks | String | A | D | AB:142; DE:79 | X |
| 52 | materialPackageUMID | String | N | D (MXF tag) | PR:129 | X |
| 53 | pairedWithID (`pendingPairedWithID`, `pairedWith`) | UUID? | P | L | `A/MediaOps/VideoScanModel+Correlate.swift:55,174,221`; `A/MediaOps/CorrelationScorer.swift:147`; resolve CatalogStore:820; `A/Volumes/VideoScanModel+ScanMerge.swift:512` | T:av_pairs + verbatim `legacy_pair_ids` <!-- F9 --> |
| 54 | pairGroupID | UUID? | P | L | Correlate:56,175; ScanMerge:513; CatalogStore:823 | T:av_pairs + `legacy_pair_ids` with the event keys citing it <!-- F9 --> |
| 55 | pairConfidence | PairConfidence? | P | S unbound | Correlate:57,176; CorrelationScorer:149 | av_pairs.confidence |
| 56 | duplicateGroupID | UUID? | P | L (machine) | DD:158 (assign), 191 (clear); DU:185 (copy-back); `A/Catalog/CatalogAuditFixer.swift:63` | T:duplicate_members (rebuildable) |
| 57 | duplicateConfidence | DuplicateConfidence? | P | S unbound | DD:160; DU:186 | duplicate_members |
| 58 | duplicateDisposition | DuplicateDisposition | A | B (keeper election) | DD:171–176; DU:187, 944, 1526 | duplicate_members |
| 59 | duplicateReasons | String | A | S | DD:162; DU:188, 945 | duplicate_members |
| 60 | duplicateBestMatchFilename | String | A | V | DD:166; DU:189, 1527 | duplicate_members |
| 61 | duplicateGroupCount | Int | A | V | DD:159; DU:190; CatalogAuditFixer:73 | drop (`count(*)`) |
| 62 | dupAnalyzedAt | Date? | P | B (stamp) | DU:192 | duplicate_groups.analyzed_at |
| 63 | lifecycleStage | LifecycleStage | A | B | MA:1314,1419; RM:39,98; `A/Catalog/VideoScanModel+Workbench.swift:36`; `A/MediaOps/VideoScanModel+Combine.swift:589`; `A/Catalog/TriageView.swift:1124`; R:460 | col CHECK |
| 64 | mediaDisposition | MediaDisposition | A | C (machine only while Unreviewed) | TriageView:1122; `A/Catalog/CatalogRowContextMenu+Organize.swift:136`; `A/Media/MediaAnalyzer.swift:259`; `A/Media/CaptionOrchestrator+Activity.swift:120`; R | T:dispositions |
| 65 | archiveStage | ArchiveStage | A | B | MA:1313,1373,1418; `A/Archive/VideoScanModel+Archive.swift:21,34`; RLc:410,611,977; RM:71,96; `A/Catalog/ShowAgain+Apply.swift:301`; R:461 | col CHECK |
| 66 | masterLocation | String | N | **unclear** (free text) | MA:1376,1377,1421; R:483 | col (Q5) |
| 67 | backupDestinations | [BackupEntry] | N | **unclear** (manual record) | VideoScanModel+Archive:31 | T:backup_destinations (Q5) |
| 68 | junkScore | Int | A | S unbound | MediaAnalyzer:255; R:463 | drop (recompute) |
| 69 | junkReasons | [String] | N | S unbound | MediaAnalyzer:256; CaptionOrchestrator+Activity:123,148 | drop (recompute) |
| 70 | starRating | Int (0–3) | N (>0) | C | `A/Catalog/InspectorPanel+Sections.swift:34`; TriageView:870; Combine:590 (max); MA:1375 (≥3); R | T:stars |
| 71 | detectedPeople | [String] | N | S unbound (faces) | `A/People/VideoScanModel+FamilyTagging.swift:80`; PT:186, 52; R | T:people_tags `detected` |
| 72 | suspectedPeople | [String] | N | S unbound | FamilyTagging:102; PT:190, 73; `A/People/ConfirmPersonSheet+Candidates.swift:175`; R | `suspected` |
| 73 | confirmedByUserPeople | [ConfirmedTag] | N | C | `A/Catalog/InspectorFamilyTagsView.swift:271,290`; PT:43; ConfirmPersonSheet+Candidates:166; R | `confirmed` |
| 74 | rejectedPeople | [String] | N | C | InspectorFamilyTagsView:283; PT:55; ConfirmPersonSheet+Candidates:188; RL:177; R | `rejected` |
| 75 | sceneCaptions | [SceneCaption] | N | S unbound (VLM) | `A/Media/VideoScanModel+SceneCaptions.swift:46,92`; DS:87; DP:117; R | T:captions `scene` |
| 76 | sceneCaptionModel | String? | P | S | SceneCaptions:93; DS:88 | T:caption_runs |
| 77 | sceneCaptionDate | Date? | P | S | SceneCaptions:94; DS:89; DE:44 | T:caption_runs |
| 78 | ocrDateCandidates | [SceneCaption] | N | S unbound | DS:92; DP:129, 240 | captions `ocrDate` |
| 79 | ocrText | [SceneCaption] | N | S unbound | DS:93; `A/FamilyTree/VideoScanModel+Documents.swift:75`; DP:124 | captions `ocrText` |
| 80 | inferredRecordDate | Date? | P | S unbound | DI:281, 469, 481, 659 | T:inferred_dates |
| 81 | inferredDateConfidence | Float? | P | S | DI:282, 470, 660 | T:inferred_dates |
| 82 | inferredDateSource | String? | P | S (names donor row!) | DI:285, 474, 1239 | T:inferred_dates |
| 83 | inferredDateRange | InferredDateRange? | P | S | DI:283, 471; DE:65 | T:inferred_dates |
| 84 | inferredDateReason | String? | P | S | DI:284, 497, 916 | T:inferred_dates |
| 85 | dossierProcessedAt | Date? | P | S | DS:133; DP:192; DE:49 | T:dossiers |
| 86 | dossierProcessedBy | String? | P | S | DS:134; DP:193 | T:dossiers |
| 87 | audioTranscript | String? | P | S unbound | `A/Media/VideoScanModel+AudioTranscript.swift:43,121`; DS:97; DP:110 | T:transcripts |
| 88 | audioTranscriptModel | String? | P | S | AudioTranscript:122; DS:98 | T:transcripts |
| 89 | audioTranscriptDate | Date? | P | S | AudioTranscript:123; DS:99 | T:transcripts |
| 90 | combinedFromPairID | UUID? | P | L | Combine:591 → CS:139 | av_pairs.combined_digest |
| 91 | sourceHost | String | A | B | `A/Catalog/VideoScanModel+CatalogImportExport.swift:120`; `A/App/VideoScanModel+BundleImportExport.swift:315` | col |
| 92 | scanContext | ScanContext | N | D/B (where scanned) | PO:143 (value ProbeEngine:910, cache :793) | `volume_uuid` + `scan_*` cols + T:volumes |
| 93 | purgedAt | Date? (derived) | P | V (= `removal.since`) | no production writer; shim `C/VideoRecord.swift:418` | drop (`removal_since`) |
| 94 | removal | RemovalMarker? | P | B (the one "gone" shape) | ONLY the engine: RM:37 stamp, 68 revert, 92 clear, 147 trash-emptied, 229 undo; R:467 | `removal_*` cols + T:tombstones |
| 95 | removalRevision | Int | P (≠0) | B (CAS tag) | RM:36, 69, 91; R:468 | col + triggers |
| 96 | auditSeenOn | AuditSeenOn? | P | S bound (stat, volume, device) | `A/MediaOps/VideoScanModel+CatalogAudit.swift:187`; cleared by `fullPath` didSet `C/VideoRecord.swift:140`; R:469 | `audit_seen_*` cols + trigger |
| 97 | setAsideReason | String? | P | B | `A/Catalog/VideoScanModel+TidyCatalog.swift:300,371,399,441`; `A/MediaOps/VideoScanModel+MissingAudio.swift:147`; R:470 | col |
| 98 | drmProtected | Bool | N | D | CaptionOrchestrator+Activity:118 | X |
| 99 | needsReformat | Bool | N | S unbound | `A/Media/CaptionOrchestrator+DossierSteps.swift:256,267`; `A/Media/CaptionOrchestrator+Dossier.swift:583` | col (Q5) |
| 100 | derivedFrom | UUID? | P | L | `A/MediaOps/TrimJob.swift:671`; MA:1284,1410; RL:428; ReformatJob:445; TranscodeJob:863; CleanupJob:589; BalanceAudioJob:755; RebuildAudioJob:701; MediaRepairJob:234; TriageView:1236; R:370 | T:lineage, or archive_copies.source_file_id |
| 101 | cleanupRecipeID | String? | P | L | `A/MediaOps/CleanupJob.swift:590` | lineage |
| 102 | cleanupRecipeVersion | Int? | P | L | CleanupJob:591 | lineage |
| 103 | derivationKind | String? | P | L | TrimJob:670; BalanceAudioJob:756; RebuildAudioJob:702; `A/MediaOps/Repair/MediaRepairJob.swift:235`; MA:1285,1411; RL:429; R:371 | lineage.kind / archive_copies |
| 104 | trimInSeconds | Double? | P | L | TrimJob:672 | lineage |
| 105 | trimOutSeconds | Double? | P | L | TrimJob:673 | lineage |
| 106 | userDate | String? (ISO partial) | P | C | `A/Catalog/InspectorDateView.swift:253,262`; `A/Archive/VideoScanModel+DateReadOnly.swift:67`; `A/ArchiveAngel/Promote/ArchiveAngelFamilyStamp.swift:94`; R | T:user_dates |
| 107 | userDateConfidence | String? | P | C | InspectorDateView:254; PromoteToArchiveJob+Steps:654,694; ArchiveUpdate:370 | T:user_dates |
| 108 | userPlace | String? | P | C | `A/Catalog/InspectorPlaceView.swift:166,175`; ArchiveAngelFamilyStamp:109; TrimJob:678 | T:user_places |
| 109 | userPlaceConfidence | String? | P | C | InspectorPlaceView:167; ArchiveAngelFamilyStamp:110; MediaRepairJob:239; RL:211 | T:user_places |
| 110 | backupAttestations | [BackupAttestation] | N | C | `A/Archive/VideoScanModel+BackupAttestations.swift:229`; ArchiveAngelFamilyStamp:139; TrimJob:680 | T:backup_attestations |
| 111 | workspaceActive | Bool | N | **unclear** (B) | TranscodeJob:864; TriageView:1227 | col (Q5) |
| 112 | audioVerifyStatus | String (`""`/ok/damaged) | N | S unbound | `A/MediaOps/VerifyAudioJob.swift:332`; CM:273 | T:media_checks `audio` |
| 113 | audioVerifyNote | String | N | S | VerifyAudioJob:333 | media_checks |
| 114 | audioVerifyDate | Date? | P | S | VerifyAudioJob:334 | media_checks |
| 115 | videoVerifyStatus | String (ok/warning/broken) | N | S unbound | `A/MediaOps/VerifyVideoJob.swift:285`; CM:271 | media_checks `video` |
| 116 | videoVerifyNote | String | N | S | VerifyVideoJob:286 | media_checks |
| 117 | videoVerifyDate | Date? | P | S | VerifyVideoJob:287 | media_checks |
| 118 | supersededByID | UUID? | P | L | RL:296, 350, 483; CatalogImportExport:163; R:368 | T:supersessions |
| 119 | repairConfirmedDate | Date? | P | C (Rick's gate) | RL:295, 342; R:369 | supersessions.confirmed_at |
| 120 | archiveFixity | ArchiveFixity? | P | S bound (whole-file SHA-256) | MA:1290,1414; `A/Archive/VerifyArchiveCopiesJob.swift:1048,1087`; ArchiveUpdate:373; ScanMerge:723; R:479 (dropped if size/MD5 changed) | `content.digest` + `files.digest_*` + archive_copies |
| 121 | contentFixity | ContentFixity? | P | S bound (SHA-256 + stat stamp) | MA:1308; VerifyArchiveCopiesJob:1058,1088; DU:959 `storeContentFixity` ← `A/MediaOps/FullHashBackfillJob.swift:305` → `A/MediaOps/CheckCopies.swift:431`, DeleteDuplicatesJob:1467, PruneApply:802; `A/Archive/FixityRebind.swift:176,189` | `content.digest` + `files.stamp_*` |
| 122 | archivedAt | Date? | P | B (Promote's stamp) | MA:1311,1416; `A/Archive/VideoScanModel+ArchivedAtBackfill.swift:50` (NOT in CLONE) | archive_copies.archived_at |
| 123 | proAppsMediaIdentifier | String? | P | D | PR:147; EB:240 | X |
| 124 | footage | FootageMembership? | P | S (machine, rewritten per run) | `A/FootageGroups/VideoScanModel+FindSimilarFootage.swift:290,293`; R:383 | T:footage_membership (rebuildable) |
| 125 | footageDecisions | [FootageDecision] | N | C | `C/FootageMembership.swift:204–209` via FindSimilarFootage:351–355; R relink :652 | T:footage_decisions (both row ids + both digests; same digest legal) <!-- F3 --> |
| 126 | familyMusic | FamilyMusicInfo? | P | C | `A/FamilyMusic/VideoScanModel+FamilyMusic.swift:35,55` | T:family_music |
| 127 | perceptualFingerprint | StoredPerceptualFingerprint? | P | S bound (size + recipe) | `A/Media/VideoScanModel+PerceptualFingerprints.swift:99,109,133`; R:492 (size match) | T:perceptual_prints |
| 128 | mediaReportCard | MediaReportCard? | P | S unbound | CM:270; MediaRepairJob:212,256 | media_checks `reportCard` |
| 129 | audioFingerprint | AudioFingerprintStamp? | P | S bound (`contentDigest`) | `A/MediaOps/VideoScanModel+AudioFingerprintBackfill.swift:48,58` ← AudioFingerprintBackfillJob:541 | T:sound_prints (sha256-keyed only) |

**Roll-up** (one role per row): D 41 · S 39 · C 14 · L 13 · B 11 · V 7 · unclear 4 = 129. **Lost on a rescan
today** (no R): every verify field, `contentFixity`, `audioFingerprint`, `mediaReportCard`, `archivedAt`,
`needsReformat`, `backupDestinations`, `junkReasons`, `workspaceActive`, all pair/dup/avid/trim/cleanup fields — the
SHA-256 among them, which is exactly why §10 keys knowledge by digest instead of trusting rescan preservation.
**Unbound stamps** (captions, transcripts, OCR, dossier, inferred dates, faces, junk, verify verdicts, report
card): a digest key does not bind them retroactively, so they import `unverified` (§e.8); only post-cutover
values (hash first, then derive) are bound. <!-- F9 -->

**Curated fields the comparator counts** (all of §10b, by field): 41, 42, 64, 70, 73, 74, 97 (set-aside reason),
106–110, 118–119 (supersession), 100–105 (lineage, as one `lineage` value), 120 + 122 (promotion: `archiveFixity`,
`archivedAt`), 125, 126, 128 (report card). Each one is a `knowledge_sources` row per occurrence. <!-- F1 -->

## b. Nested types

| Type (file) | Fields | Role | Fate |
|---|---|---|---|
| `ContentFixity` `C/ContentFixity.swift:250` | algorithm ("sha256" :262), digest (lower hex), byteCount, stamp: `FileIdentityStamp` (:83 device, inode, size, mtimeNs, ctimeNs (−1 unknown :100), volumeUUID?), computedAt | S bound — THE identity when `byteCount == sizeBytes` (`storedFullDigest`, `A/MediaOps/Cleanup/VideoScanModel+Cleanup.swift:124`) | digest → `content`; stamp → `files.stamp_*`; computedAt → `digest_computed_at` |
| `ArchiveFixity` `C/ArchiveFixity.swift:17` | algorithm, digest, verifiedAt, sizeBytes | S bound (archive copy, read-back at promotion) | same digest column; verifiedAt → `archive_copies.fixity_verified_at` |
| `AudioFingerprintStamp` `C/AudioFingerprintStamp.swift:37` | computedAt, engineVersion, contentDigest ("sha256:…" or "v1:…"), sizeBytes, outcome (fingerprinted / noAudio), analyzedSeconds, complete, landmarks, bytes | S bound | `sound_prints` when `contentDigest` is `sha256:`; a `v1:`-keyed stamp is NOT imported (the next run redoes it) |
| `RemovalMarker` `C/RemovalMarker.swift:64` | state (inTrash / removedFromCatalog / missing), since, reason (`RemovalReason` open string, 16 named :43–60), trashPath?, trashEmptiedSeenAt?, lastSeen? | B | `files.removal_*` + `tombstones` |
| `AuditSeenOn` `C/AuditSeenOn.swift:27` | volumeUUID, mountFrom?, seenAt, deviceKey? | S bound (stat through a handle) | `files.audit_seen_*` |
| `ScanContext` `C/ScanContext.swift:24` | scanHost, volumeUUID, volumeMountType, volumeName, remoteServerName, scannedAt?, scanRootLabel, bundleContainer | D/B | `files.volume_uuid` (FK `volumes`), `scan_*`; name/mount/server → `volumes` |
| `BackupEntry` `C/ArchiveModels.swift:68` | name, kind (Local / Cloud / Offsite), date | unclear (Q5) | `backup_destinations` |
| `ConfirmedTag` `C/Tagging.swift:39` | name, confirmedAt | C | `people_tags` (confirmed) |
| `SceneCaption` `C/Tagging.swift:20` | timestamp, text | S | `captions` |
| `InferredDateRange` `C/InferredDateRange.swift:18` | startYear, endYear | S | `inferred_dates.range_*` |
| `BackupAttestation` `C/BackupAttestation.swift:57` | kind (cloud / offsite / drive), answer (yes / no / notApplicable), label?, attestedAt, by | C | `backup_attestations` |
| `FootageMembership` `C/FootageMembership.swift:115` | groupID, groupSize, confidence, role, rank, likelyOriginalID, originalInCatalog, evidence, scannedAt, algorithmVersion | S (machine) | `footage_membership` JSON |
| `FootageDecision` `C/FootageMembership.swift:171` | otherID (a ROW id), verdict (same / notSame), decidedAt | C | `footage_decisions`: owner row id + `otherID` + both digests (NULL-able) <!-- F3 --> |
| `FamilyMusicInfo` `C/FamilyMusicInfo.swift:22` | performer?, title?, markedAt | C | `family_music` |
| `StoredPerceptualFingerprint` `C/StoredPerceptualFingerprint.swift:36` | algorithmVersion, hashesBase64, sizeBytes, durationSeconds, computedAt | S | `perceptual_prints` |
| `MediaReportCard` `C/MediaReportCard.swift:182` | tier (quick / full), checkedAt, fileSizeBytes, headline, checks, repairedCopy?, measuredPictureSeconds? | S | `media_checks.card` JSON |

Enums (CHECK lists in the DDL): `LifecycleStage` `C/ArchiveModels.swift:15` (Cataloged, In Triage, Workbench,
Archived, Trashed, Deleted); `MediaDisposition` :39; `ArchiveStage` :47 (None … Salvage Failed); `StreamType`
`C/MediaClassification.swift:14`; `PairConfidence` :28 / `DuplicateConfidence` :41 (High/Medium/Low);
`DuplicateDisposition` :52 ("", Keep, Review, Extra copy); `VideoVerifyVerdict` `A/MediaOps/VerifyVideoRules.swift:114`;
audio status from `A/MediaOps/VerifyAudioProbe.swift:262`. **Derivation kinds**: trim (`A/MediaOps/TrimEngine.swift:217`),
balanceAudio (`BalanceAudioJob.swift:73`), rebuildAudio (`RebuildAudioJob.swift:52`), repair (`MediaRepairJob.swift:42`),
externalRepair (RL:41), archivePromotion (`C/VideoRecordUserDate.swift:256`). Reformat, Transcode, Cleanup and Triage set
`derivedFrom` with NO kind; the importer names them from their own fields (cleanup ⇐ `cleanupRecipeID`) or
`unrecorded` — never guessed.

## c. Sidecars

| File | Shape | Keyed by | Writer | Fate |
|---|---|---|---|---|
| `events-decisions.json` (+`.prev`) | `EventsDecisionFile {storeVersion 1, savedAt, events:[EventRecord], decisions:[EventDecision]}` `A/Events/EventsDecisionStore.swift:154`; membership = folded `member` decisions (:173) | `ContentRange.contentKey` (:35): full SHA-256, else `pair:<pairGroupID>`, else `id:<recordID>` | `EventsDecisionWriter.write` :600 (atomic, `.prev`) | `events`, `event_decisions` (verbatim), `event_members` by digest |
| `events_latest.json` | `EventsStats` counts (`A/Events/VideoScanModel+Events.swift:120`) | none | `EventsStats.write` :219 | stays a file (metrics) |
| `ignored-content.json` | `IgnoredContentFile {entries:[{id, partialMD5, sizeBytes, filename, reason, addedAt, samplePath}]}` `A/Catalog/IgnoredContentStore.swift:76,109` | (partialMD5, size); fallback (filename, size) — **sampled**; no row id, no digest | `saveOffMain` :338 | `ignored_content`, `unbound` (Q4) <!-- F7 --> |
| `catalog-audit.json` | `CatalogAuditRunRecord {startedAt, finishedAt?, outcome, partial, counts, marked}` `A/MediaOps/CatalogAuditRun.swift:25` | today none — **no per-row result**; A′ adds per-row results (present / gone / neverSeen / couldNotCheck / changed / link) by record id, each non-present one with the path it was judged at, and `savedGeneration` (the generation its stamp save produced) | `CatalogAuditRunMarker.persist` :132 | `job_markers` (job=audit) + `audit_results` per row <!-- F6 N1 --> |
| `personfinder_cache.sqlite` | `pf_cache(video_path, file_size, mod_date, person_name, engine, threshold, ref_hash, duration_seconds, fps, total_hits, segments_json, cached_at)` `A/People/PersonFinderCache.swift:78–91` | (path, size, mtime, person, engine, threshold, ref hash), latest only (`INSERT OR REPLACE` :315) | `store` :311 ← `PersonFinderModel+JobLifecycle.swift:1152` (result, zero hits included) and :1162 (unreadable: 0 hits, 0 s, 0 fps) | `person_searches`, `unverified` (§e.8) <!-- F9r3 --> |
| `fullhash-backfill.json` | `{startedAt, finishedAt?, hashedSoFar}` `A/MediaOps/FullHashBackfillResume.swift:26` | none | `persist` :99 (MOPS-13) | `job_markers` (job=fullHash), body verbatim in `detail`; an importer input <!-- F1 --> |
| sound-print backfill | no resume file (`A/MediaOps/AudioFingerprintBackfill.swift:18`) | — | — | — |
| freshness stamps | not persisted separately; per-row stamps + the two markers above (`A/Analyze/AnalyzeCoverage.swift:1–27`) | — | — | the stamps' tables + `job_markers` |
| `integrity-latest.json`, `integrity-<date>.json` | `IntegrityReport` schema 2 `A/Integrity/IntegrityReport.swift:146`: run, generations, catalogSHA256, tiers, findings ≤ 5,000 (:151) | tier int; findings by **record UUID** (:136) | `IntegrityReportStore.write` :289 (MOPS-15) | `integrity_runs`; files stay as the dated history |
| `ledger/media-ledger.jsonl` | `MediaLedgerEvent {at, event, recordID, contentKey, filename, fullPath, by, batchID?, detail}` `C/MediaLedgerEvent.swift:31`, 18 kinds :35 | recordID + `contentKey` = `h:`+**v1 contentHash** or `p:md5:size` (:183) + path | `MediaLedger.append` `A/Archive/MediaLedger.swift:102` (O_APPEND + fsync) | `ledger` (append-only) + the JSONL kept |
| `audio-fingerprints.sqlite` | `fingerprints(content_digest, size_bytes, engine_version, …, blob)` PK the three, `C/AudioFingerprintStore.swift:177–204` | self-describing digest (`sha256:` or `v1:`) + size | `put` :262 | stays its own DB (§9b); bound through `sound_prints.sidecar_key` |
| `catalog.generation.max` | one integer | none | `A/Catalog/CatalogGenerationSidecar.swift` via CatalogStore:510,552,792 | NOT in the database: a file beside it, renamed `catalog.highwater`, written BEFORE each commit, plus a `generationHighWater` ledger line (§e.9) <!-- F8 F8r3 --> |
| `date-inference/unwound-*.json` | `UnwoundDateSidecar` (DI:1099) | recordID + fullPath (DI:1075) | DI:1285 | stays (undo history) |
| `archive-angel/evidence.json` | `[UUID: ArchiveAngelEvidenceRecord]` | record UUID | `ArchiveAngelEvidenceStore.saveOffMain` :473 | rebuildable cache — not imported |
| `delete-duplicates/<plan>/plan.json` | targets: path + recordID? (`A/MediaOps/DeleteDuplicatesPlan.swift:89–172`) | path | rewritten per pair | import gate: **no open plan** |
| `media-person-links.json` | `{personID, mediaHash (partialMD5), mediaPath, source, notedAt}` `A/Media/MediaPersonLinks.swift:144` | (personID, **partialMD5**) | — | out of the catalog; never bound by sampled match (Q4) <!-- F7 --> |
| `cyberbrain/cyberbrain.json` | people knowledge; photo captions cite **absolute path** | person id | `C/CyberBrainWriter*.swift` | out of scope; path-keyed (Q4) |
| `metadata_cache.sqlite`, `catalog.search-index.v1.plist` | probe cache, search index | path | — | rebuildable, not imported |

## d. Invariants → engine or job

`Integrity/CatalogConstraints.swift` holds **15** rules (`Rule` :167–181; A′ added `referenceMovie`): 14 are tier 5,
and `derivedStampsMatchContent` is tier 4. All 15 map: <!-- F5 -->

| # | Rule | SQLite | Kind |
|---|---|---|---|
| 1 | uniqueIDs | `files.id` PK + `files_no_replace`; quarantine keyed by `(import_run, source_ordinal)`, `json_row_id` non-unique: a duplicated JSON id quarantines EVERY occurrence as its own row <!-- F4 --> | PK + trigger |
| 2 | oneLiveRowPerPath | `files_live_path` UNIQUE (volume_uuid, full_path) WHERE live | partial UNIQUE |
| 2b | referenceMovie | quarantine reason `referenceMovie` (a finding reason: a rescan's byte match never resolves it) <!-- F5 --> | job, no I/O |
| 3 | lineageTargetsExist | `lineage`, `supersessions` FK → `content` RESTRICT; `archive_copies.source_file_id` FK → `files`; rows never deleted | FK |
| 4 | promotionsHaveASource | `archive_copies_need_source` (only `promoted_by='import'` may carry NULL, with its finding) | trigger |
| 5 | removalMirrorsLifecycle | CHECK `removal_state IS NOT 'inTrash' OR lifecycle='Trashed'` | CHECK |
| 6 | requiredFields | NOT NULL; CHECK path non-blank and absolute; `size_bytes >= 0` | CHECK |
| 7 | wholeFileDigestsAreWhole | `content.digest` CHECK 64 lower hex; `files.content_digest` FK; `sampled_hash GLOB 'v1:*'` in its own column; size = byte_count trigger | CHECK + FK + trigger |
| 8 | removalRevisionNonNegative | CHECK ≥ 0; `files_removal_revision_monotonic`; `files_removal_change_bumps_revision` | CHECK + trigger |
| 9 | auditStampNamesItsVolume | CHECK non-blank; stamp ⇔ seen_at; `files_path_change_clears_audit_stamp` (= `C/VideoRecord.swift:140`) | CHECK + trigger |
| 10 | eventMembersExist | `event_members.digest` FK | FK |
| 11 | pathAliasByCase | `volumes.case_sensitive` decides; `files_live_path_fold` UNIQUE (volume_uuid, path_fold) WHERE live AND case-insensitive volume refuses the alias; on a case-sensitive volume both rows are legal and not reported <!-- F12 -->. `path_fold` is the APP's NFC + case fold (`folding(options: [.caseInsensitive], locale: nil)`; diacritics kept), stored; the engine compares stored folds, never SQLite's ASCII-only `lower()`. `É.mov` → `é.mov` is accepted; `A.mov` beside `a.mov` is refused. A stale fold → new tier-5 rule `pathFoldMatchesPath` (A′) <!-- N3 --> | partial UNIQUE + job |
| 12 | supersessionCycle | `supersessions_acyclic` (recursive CTE) + `supersessions_no_rewrite` | trigger |
| 13 | duplicateGroupDigestsAgree | narrowed rule (`CatalogConstraints.swift:515–524`): a candidate group may hold different digests; a group formed on a `hash` reason with differing digests is a finding — view `duplicate_hash_groups_disagree`, read by the job. v1's one-digest trigger is removed <!-- D:530 --> | job (view) |
| 14 | derivedStampsMatchContent (tier 4) | structural: every stamp table's key IS the digest it was made from; a changed file is a new row with a new digest | retired by the key |

**MOPS** (`docs/practices/invariants/MediaOps.md`). Need I/O → **stay jobs**: MOPS-1/2 (surviving copy proven at
delete time), 4/5, 7 (one transaction per item), 8, 10, 11, 12 (receipt CSV stays a file). Engine support: rows never deleted (tombstones); MOPS-3 → `archive_copy_never_trashed`; MOPS-6 (the record
follows only a verified copy) → `files_digest_immutable` + the size trigger, so a moved path must carry the same
content; MOPS-9 → the sink + `ledger`; MOPS-13 → `job_markers`; MOPS-14 → removal triggers (every marker field, tombstone required, F11) + audit-stamp CHECK and
trigger (the proof walk stays a job); MOPS-15 → Verify Catalog runs in one read transaction (a true snapshot) and
writes `integrity_runs`.

## e. Identity

**The content identity is the whole-file SHA-256**: 64 lowercase hex, algorithm `sha256`, from `contentFixity`
(when `byteCount == sizeBytes`) else `archiveFixity` (when `sizeBytes` matches) — exactly `storedFullDigest`
(`VideoScanModel+Cleanup.swift:124`). The sampled `v1:` `contentHash` and `partialMD5` are NEVER identity
(integrity_first §2.4; `CatalogConstraints.digestShapeProblem` :333). Where the rule bites the schema:

1. `content.digest` CHECK makes a `v1:` value unstorable as identity; `sampled_hash` lives in `files` with a GLOB and
   nothing references it.
2. `files.content_digest` is NOT NULL → **a row without a whole-file digest cannot enter `files`**; it goes to
   `quarantine` with its full JSON (§f). This is the price of the rule, paid once: A′'s hash run shrinks it.
3. Every knowledge table is keyed by digest: byte-identical files show one value (Q1), and a rescanned file at a
   new path re-attaches without an id or path match. The shown value is a **display choice**; every occurrence's
   own value stays in `knowledge_sources` (§e.10). <!-- F2 -->
4. A file whose bytes change is a NEW row (`files_digest_immutable`); the old content's knowledge stays on the old
   digest — never silently carried onto other bytes.
5. Archive promotion copies bytes, so the archive copy and its source share a digest: promotion is file → file
   (`archive_copies`), not content lineage. Derivatives (trim, repair, …) are other bytes: `lineage` digest → digest.
6. Sound prints: only `sha256:`-keyed stamps import (prefix stripped). The ledger, the ignored list, person links
   and v1 prints carry sampled keys: verbatim, never identity. **A sampled key never binds**, not even when exactly
   one hashed file matches it (codex: an ignored file is gone and a different file shares its partialMD5 and
   size). An entry binds to a digest only when (a) the original row's whole-file digest is known from the JSON, or
   (b) a person decides; else `unbound`. An ignored entry carries no row id or digest
   (`IgnoredContentStore.swift:76`), so all import `unbound`; a ledger line binds through its `recordID`'s JSON
   digest. <!-- F7 -->
7. Knowledge whose writer named a ROW is translated to digests at import through that row's digest:
   `inferredDateSource = "propagated from <uuid>"`, `FootageDecision.otherID`, events `id:`, `pair:`. The row id
   is ALSO kept verbatim (`footage_decisions.row_id/other_row_id`, `regen_context`, `legacy_pair_ids`,
   `lineage_pending`). When the row has no digest, the item is kept by row id, never dropped. <!-- F1 F3 F9 -->
8. **Derived provenance.** A derived value imports as `bound` under a digest only when its stamp names that
   digest, or when the row's fixity stamp (inode / size / mtime / ctime) equals the stat stamp the value was
   computed against. Otherwise it imports as `provenance = 'unverified'`: kept, not shown as fact, and replaced
   when the cyclers regenerate it. **What the source carries** (read in `C/VideoRecord.swift:254–349`,
   `C/Tagging.swift:20`, `C/StoredPerceptualFingerprint.swift:41–48`, `C/MediaReportCard.swift:190–195`):
   - Captions and OCR (`SceneCaption` = timestamp + text) carry only `sceneCaptionModel` / `sceneCaptionDate`.
   - Transcripts carry model + date. Dossiers carry `processedAt` / `processedBy`.
   - Verify verdicts carry a date. The perceptual print carries `sizeBytes`. The report card carries `fileSizeBytes`.
   - Faces and inferred dates carry nothing.
   - **None of them carries path, inode, mtime or ctime.** So none can meet the stat-stamp test: every one of them
     imports `unverified`. Only `AudioFingerprintStamp.contentDigest = sha256:…` imports `bound`.
   - Size alone is not a stamp.
   - A time-window argument ("derived after `contentFixity.computedAt`, and the stamp still matches now") is
     possible but NOT adopted here. It is Rick's call (§h Q6).

   **Where they land** <!-- N2 -->:
   - Per-content tables (`captions`, `transcripts`, …) hold **bound** values only, keyed (digest, kind, seq).
   - **Unverified** values (all imported derived values but `sha256:` sound prints, names included) go to
     `derived_unverified`, keyed (digest, kind, seq, `source_json_row_id`). Two same-digest rows with
     different first captions both land, and a trigger flags both `conflict = 1`.
   - A second bound value for a key: byte-identical is dropped (`RAISE(IGNORE)`); different is refused, and
     the writer moves BOTH to `derived_unverified` with `conflict = 1`.

   Context that regeneration cannot recover from the file is preserved:
   - folder-derived and donor-derived dates, with their source and reason (`regen_context` `folderDate` /
     `donorDate`);
   - the original `pairedWithID` / `pairGroupID`, together with the event member keys that cite them
     (`legacy_pair_ids`).

   <!-- F9 -->

   **Search evidence** <!-- F9r3 -->: `person_searches`, one row per (file, search), zero hits included. r2's
   `personSearched` read `detectedPeople` / `suspectedPeople`, which are a search's *outputs*; it is removed.
   What carries search evidence today (read in `A/People/`):
   - **catalog.json: none.** Detected / suspected names are hits only (FamilyTagging:80, :102);
     `mediaReportCard` is media health. Find & Tag writes names on hits and log lines (`FindPersonJob.swift:902`).
   - **`personfinder_cache.sqlite` `pf_cache`**: per (path, size, mtime, person, engine, threshold, ref hash),
     `total_hits` with zeros. Partials are not stored (`shouldStore` :18). An unreadable file is stored as
     0 hits / 0 s / 0 fps (JobLifecycle:1162) and imports as `outcome = 'unreadable'`, not a miss.
   - `scan_jobs/*.json` (`ScanJobsStorage.swift:26`) holds per-search totals, not per file, and is not
     imported. `validation_labels.json` holds confirmations, not searches.

   Each `pf_cache` row imports `unverified`, with the key verbatim. Its `source_json_row_id` / `digest` come
   from the one catalog row whose `fullPath` and `sizeBytes` match the key, otherwise NULL. A path key never
   binds identity. SQLite-era searches write `bound` rows.
9. **Generation and high-water.** The CAS runs inside the write transaction:
   `UPDATE generations SET generation = generation + 1 … WHERE id = 1 AND generation = :expected`.
   `changes()` must be 1, else ROLLBACK. The high-water is not in the database (a restore would rewind it):
   it lives in `catalog.highwater` beside the database, one integer, never lowered. <!-- F8 -->
   **Two-phase, high-water FIRST** <!-- F8r3 -->. Every write advancing from g:
   (1) write `catalog.highwater` = g+1 (temp, fsync, rename, fsync dir) and append
   `generationHighWater {intended: g+1}` to the JSONL ledger (fsync);
   (2) commit the CAS g → g+1.
   So codex's crash after commit 6, followed by a restore of 5, is caught: (1) already recorded 6.
   **Effective high-water at open** <!-- F8 final -->: the larger of `catalog.highwater` and the newest
   `generationHighWater` line in the JSONL ledger — read BOTH on every open. A restore that rewinds the
   database and its sidecar together (codex r3: commit 6, restore both to 5) is caught by the ledger, which
   is append-only and lives apart from the database; a ledger that cannot be read is itself a named refusal.
   **Invariant at open:** `effective highwater ≥ generation`.
   - `highwater > generation` ⇒ a restore, or a crash between (1) and (2); only the JSONL's last line tells
     them apart. Either way: READ-ONLY (`restoredBelowHighWater`), words naming the case, until a person adopts.
   - `highwater < generation` ⇒ the file was rolled back; it is raised to the generation.

   **Adoption** is explicit, not a CAS. In one transaction: insert a `generation_history` row with kind `adopt`
   (generation :hw, `from_generation` :old), then
   `UPDATE generations SET generation = :hw, adopted_at = now, adopted_from = :old WHERE id = 1 AND :hw > generation`.
   The step trigger allows the jump only with that row. SQLite cannot see transactions, so the binding is by
   shape: the adopt row is insertable only while the counter reads :old, and while one sits above the counter
   every +1 is refused. Reproduced from 6, because the F8 block took 5 → 6 by CAS: 6 → 10 by plain UPDATE
   fails, and by adoption succeeds.
10. **No curated value is merged away.** `knowledge_sources` keeps one row per (occurrence, field), verbatim:
    `(import_run, source_ordinal, json_row_id, digest NULL-able, field, value_json, set_at, source)`. The
    per-content tables (`user_notes`, `stars`, `user_dates`, `user_places`, `dispositions`, `family_music`,
    `people_tags`, `backup_attestations`) hold the display value the Q2 rule picks, plus `conflict`. `conflict` is
    1 whenever the copies' values differ. A tie leaves the display NULL with `conflict = 1`.
    Specific shapes:
    - Date and place confidence are NULL-able and independent of the value (`VideoRecord.swift:909–914`). <!-- F3 -->
    - Footage decisions keep both row ids and both digests. Two rows sharing one digest are a legal pair
      (`FindSimilarFootage.swift:349–352`). <!-- F3 -->
    - A name confirmed on one copy and rejected on another is two rows, both `conflict = 1`. Neither verdict
      suppresses the other. <!-- F2 -->

## f. Importer gate (§10a D′)

**Inputs**:
- `catalog.json` (frozen read-only first, then SHA-256'd);
- `integrity-latest.json`;
- `catalog-audit.json`, with A′'s per-row results;
- `fullhash-backfill.json`; <!-- F1 -->
- `events-decisions.json`, `ignored-content.json`, `ledger/media-ledger.jsonl`;
- `personfinder_cache.sqlite`, opened read-only (§e.8 search evidence). <!-- F9r3 -->

**Run-level refusals** (nothing is written):
- JSON version > 6.
- The integrity report: `outcome ≠ completed`, or `catalogHashCertified = false`, or `catalogSHA256 ≠` the frozen
  file's hash, or `snapshotGeneration ≠` the file's generation.
- **One snapshot** <!-- N1 -->: the audit's `savedGeneration` ≠ `snapshotGeneration` or ≠ the file's generation.
  Every save bumps the generation, so ANY save after the audit (rename, move, tag) refuses the import
  (CHECKs on `import_runs`).
- `findingsTotal > findings.count`. Findings are capped at 5,000, and a truncated list cannot gate rows: rerun
  after fixing.
- Tiers 0, 1 or 5 `notRun`.
- `catalog-audit.json` is missing, `partial`, has outcome ≠ completed, finished after the integrity run started,
  or **carries no per-row results** (an audit from before A′). <!-- F6 -->
- An event id appears twice in `events-decisions.json`. <!-- F4 -->
- Any open `delete-duplicates/` plan or Archive Angel batch.
- The app or the headless audit is running (one writer).

**Per-row inputs.**
- *Audit* — the row's result from `catalog-audit.json`, written by Tier 0. The importer does NOT stat or open
  anything. v1's "one `lstat`" design is removed: `lstat("/linked-dir/movie.mov")` follows an ancestor link and
  all three stamps can still agree. Tier 0 walks each path component by component from the volume root, binding
  each step to an fd (`openat`, `O_NOFOLLOW`), refuses a link at any component, and `fstat`s the opened file
  against the fixity stamp. The results are `present`, `gone` (ENOENT on a mounted volume, by the audit's proof
  rule), `neverSeen`, `couldNotCheck`, `changed` and `link`. A row with no result reads as `neverSeen`. This
  answers Q3. <!-- F6 -->
  **A result gates its row only when bound to the snapshot** <!-- N1 -->:
  - `present` is accepted only when the row's own `auditSeenOn` exists in the frozen JSON and its `seenAt` lies
    within the audit's [startedAt, finishedAt]. The model clears the stamp on ANY `fullPath` change
    (`C/VideoRecord.swift:140`), so a moved row cannot carry an old `present`.
  - Any other result is refused when the path it was judged at differs from the row's `fullPath`.
  - A refused result is kept (`accepted = 0`, recomputed by trigger) and the row reads as `neverSeen`.
- *Digest* — `storedFullDigest(r)`. When both fixities exist they must agree. An archive-only fixity has no stat
  stamp (`MasterArchive.swift:1290–1297`); it counts as "digest known, seen = the audit result", with nothing to
  compare. <!-- F10 -->
- *Tier 5* — any finding with this `recordID` and `needsDecision`.
- *Marker* — the `removal` state, or nil.

**Precedence (first match wins).** This is a partition: every occurrence lands in exactly one row. <!-- F10 -->

| # | When | → | Reason code / words |
|---|---|---|---|
| 1 | its UUID occurs more than once in `catalog.json` | quarantine, EVERY occurrence | `duplicateId` — "this catalog entry appears N times; each copy kept" |
| 2 | both fixities present and they disagree | quarantine; `digest` NULL, both in `evidence_digests` | `fixityDisagree` — "two full hashes disagree; neither is trusted" |
| 3 | marker set, digest known, no tier-5 finding | **main, tombstoned** (marker + revision kept, revision 0 allowed) | — |
| 3b | marker set, digest known, tier-5 finding | quarantine | `tier5Finding` / `referenceMovie` |
| 3c | marker set, no digest | quarantine | `removedNoDigest` — "left the catalog before its identity was read; kept as history" |
| 4 | audit `gone` | quarantine | `auditGone` — "not at its path when last checked" |
| 4b | audit `neverSeen` (or no result) | quarantine | `auditNeverSeen` — "no audit has seen this file — Fix Links decides" |
| 4c | audit `couldNotCheck` or `link` | quarantine | `auditCouldNotCheck` — "its drive was not connected, or a link is in the path" |
| 4d | audit `changed` | quarantine | `auditChanged` — "the file changed since its identity was read" |
| 5 | audit `present`, no digest | quarantine | `noWholeFileDigest` — "on disk, but its identity was never read in full; Fill In Full Hashes, then rescan" |
| 6 | audit `present`, digest, any tier-5 finding | quarantine | `referenceMovie` for that rule, else `tier5Finding` — the finding's own words |
| 7 | audit `present`, digest, tier-4 finding only (stale print) | **main**; the stale stamp imports `unverified` (§e.8) | listed in the import report |
| 8 | audit `present`, digest, no finding | **main** | — |

A main row whose live path collides with another main row (rule 2, or its case alias on a case-insensitive volume)
is caught at step 6 as a tier-5 finding; the UNIQUE indexes are the backstop.

**Findings are never dropped** <!-- F5r3 -->. A quarantine row's `findings` holds EVERY tier-5 finding for its
recordID, whichever reason won. Codex's `auditGone` row keeps its `referenceMovie` finding, and that finding
closes the byte-match door (§g Step B).

**What every occurrence writes.** Plain INSERT only. There is no `INSERT OR REPLACE` anywhere in the importer, and
a duplicate is a finding, never a replacement. Each evidence table also refuses a replace by trigger. <!-- F4 -->
- One `import_items` row per occurrence in every input file, naming the one table row it landed in
  (`files.id`, `quarantine.qid`, or the `(run, ordinal)` row of `event_decisions` / `ignored_content` / `ledger` /
  `job_markers` / `audit_results`). <!-- F1 -->
- For a catalog row: `curated_fields` (the §10b fields it carried) and one `knowledge_sources` row per field. The
  `digest` is NULL when the row has none or its fixities disagree. A digest-bearing row also feeds the display
  tables (Q2). <!-- F1 F2 -->
- Lineage and supersession go into `lineage` / `supersessions` when both ends have digests. Otherwise the edge
  goes into `lineage_pending` by row ids, and is never dropped (codex's main child with a digest-less parent). An
  archive-promotion `derivedFrom` is `archive_copies.source_row_id`, verbatim, with `source_file_id` NULL while the
  source is quarantined. <!-- F1 -->
- Derived values go in with `provenance` per §e.8 (unverified ones in `derived_unverified`, keyed by source
  row); `regen_context` and `legacy_pair_ids` per §e.8. <!-- F9 N2 -->
- Each `pf_cache` row → one `person_searches` row and one `import_items` row. <!-- F9r3 -->
- Events: the decision stream verbatim, membership and non-membership decisions alike, plus the fold. A member key
  resolves `sha256` → digest, `pair:` → both halves' digests, `id:` → that row's digest. An unresolvable member
  stays in the stream and in `legacy_pair_ids`, and is listed against its row. <!-- F1 -->

**Reconciliation line** (one OUTCOME line through the sink):
`rows before N · main M (live L, tombstoned T) · quarantine Q (by reason …) · digests D · knowledge rows K (by
field) · conflicts C (by table) · unverified U (conflicts) · pending lineage P · events E (decisions, members
resolved / listed) · ignored I (bound / unbound) · ledger lines J · searches S (zero-hit Z, unreadable R) · audit
results A (accepted / refused) · markers`. <!-- N1 N2 F9r3 --> The `import_runs` counters are NOT the proof. A run is inserted open
and finished by one UPDATE, which a trigger refuses unless:
- the counters equal counts of the rows;
- every `import_items` landing exists, and no two occurrences landed on one `files` row;
- every listed curated field has its `knowledge_sources` row;
- every lineage or supersession value is an edge or a pending edge;
- every footage decision is a `footage_decisions` row.

`rows_before = rows_main + rows_quarantine` stays only as a CHECK backstop. <!-- F1 -->

**Comparator** (independent: it re-decodes every input file by its own path and reads SQLite by SQL). It checks
**rows, not counters**:
- every JSON row occurrence → exactly one of `files` / `quarantine`, by (run, ordinal);
- its curated fields, decoded independently, equal the occurrence's `curated_fields`, and each equals its
  `knowledge_sources.value_json` (set-aside reason, promotion fields, lineage, report cards and footage decisions
  included);
- every event decision (membership AND non-membership) → `event_decisions`;
- every marker file (`catalog-audit.json`, `fullhash-backfill.json`) → `job_markers`;
- every per-row audit result → `audit_results`, with `accepted` recomputed by the N1 rule;
- every `pf_cache` row → `person_searches`, zero hits included; <!-- F9r3 -->
- every derived value → its bound table or `derived_unverified`, by (digest, kind, seq, source row); <!-- N2 -->
- every ledger line → `ledger`;
- every ignored entry → `ignored_content`;
- every distinct agreeing whole-file digest → `content`.

Any miss → ROLLBACK, the SQLite file is deleted, and the report names the miss. The import is one transaction; the
JSON is never written. <!-- F1 -->

## g. Reconciliation by digest — the rescan (§10a E′)

The walk is the audit's fd-bound walk: component-wise `openat` with `O_NOFOLLOW` from the volume root, refusing a
link at any component. Probing and hashing read through the verified fd, and every stamp comes from `fstat` of that
fd. A path is never re-resolved between check and hash. <!-- F6 -->

Per mounted volume, per media file:
1. **Still-being-written rule** (A′ adds it; no such rule exists in the code today). Two `fstat`s ≥ 30 s apart
   must agree on size and mtime, and the mtime must be ≥ 2 min old. Then hash, then `fstat` again: the stamp must
   equal the first. Any disagreement → not catalogued this run, listed as `stillBeingWritten` (deferred; never a
   row, never a quarantine resolution).
2. ffprobe + whole-file SHA-256, bound to the stamp.
3. Two separate steps follow.

**Step A — file reconciliation** (writes `files` / `content` only): <!-- F5 -->

| Case | Action |
|---|---|
| live row at (volume, path) with the same digest | refresh disk facts + stamp; nothing else |
| live row at (volume, path) with a **different digest** (the file was replaced) | old row → removal `removedFromCatalog`, reason `replacedAtPath` (a new `RemovalReason`), tombstone first; NEW row for the new digest; knowledge stays with the old digest; listed |
| **known digest at a new path**, and exactly one live row with that digest is proven gone from its own path (the audit's proof rule) | that row's path is updated through the store's one path door (keeps its id; the trigger clears the audit stamp; the app recomputes `path_fold`, N3) |
| known digest at a new path, its other rows still present (or several gone) | new row (a copy); knowledge shared by digest; gone candidates left to the audit |
| digest known only from a **quarantined** row (no main row has it) | new `files` row; `id` = `json_row_id` only when that id occurs once in the import and is not in `files`, else fresh. File-level fields from `raw_row` (a `missing` marker is not carried: the file was found) |
| **new digest** | new `content` + `files` rows; no knowledge |

**Step B — quarantine resolution** (writes `quarantine.resolved_*` only, after Step A): <!-- F5 -->
- A row is resolved by the rescan (`foundByDigest` / `resolvedAsCopy`) ONLY when its reason is a **presence**
  reason (`auditGone`, `auditNeverSeen`, `auditCouldNotCheck`, `noWholeFileDigest`, `removedNoDigest`) **AND its
  `findings` array is empty**. One CHECK spans `reason_class` and `findings`. `findings` is immutable after
  insert, so it cannot be emptied to open this door. <!-- F5r3 -->
- A row WITH findings is resolved only by `resolvedByRule`: the rule name and the integrity run id that no
  longer reports it, both CHECK-enforced. `personDecided` is refused on it. <!-- F5r3 -->
- `foundByDigest`: Step A created the file row for this row's digest, and no main row carried that digest.
- `resolvedAsCopy`: the digest matches a main row AND this quarantined row. The file at the new path is a second
  `files` row (a copy), and the quarantine row points at it. Nothing collides.
- **Finding** reasons (`tier5Finding`, `referenceMovie`, `fixityDisagree`, `duplicateId`, and `auditChanged`,
  which the Manager's list did not name: classed here as a finding, Q6) stay open after a byte match. Only their
  own rule clears them (`resolvedByRule`, as above), or a person (`personDecided`) when the row carries no
  finding. A returning reference movie is reconciled as a file in Step A, but its quarantine row stays
  open until its external media are accounted for. <!-- F5r3 -->
- `noWholeFileDigest` / `removedNoDigest` rows have no digest to match. Their route is a candidate offered to Rick
  (sampled hash + size + name match a new file) → `personDecided`, never automatic. <!-- F7 -->
- A quarantined row that is never found stays open with its words: history, never deleted.

Rescan reconciliation line: `walked · in place · moved · copies · replaced · quarantine resolved (found / as copy) ·
findings still open · new · deferred · links refused · unreadable`. Live rows on the volume that the walk did not
see are NOT marked by the rescan: the audit owns "gone".

## h. Open questions for Rick (6)

1. **Curated knowledge per content, not per file**: byte-identical copies show one value (today they can differ).
   *Recommend: yes — the §10 rule; Promote already propagates these (MA:1312–1344); per-copy originals stay in
   `knowledge_sources` (§e.10).* <!-- F2 -->
2. **Display choice when copies disagree.** *Recommend:*
   - Sets (tags, attestations, footage verdicts) show the union.
   - A `rejected` name hides the same machine (`detected` / `suspected`) name.
   - A name confirmed on one copy and rejected on another is a conflict (both rows shown flagged).
   - Scalars: `known` beats `estimated`; then the latest `dateSet` / `placeSet` ledger line for those rows; then the
     archive copy's value. The display is that pick with `conflict = 1`. Anything still tied shows empty with
     `conflict = 1` until you choose.
   - Nothing is merged away: every original stays in `knowledge_sources`. <!-- F2 -->
3. **Per-row audit evidence.** *Answered:* Tier 0 writes per-row results; the importer walks nothing (§f). <!-- F6 -->
4. **Sampled-hash stores** (ignored list, person links, ledger `contentKey`, `v1:` prints). *Answered:* verbatim,
   never identity, never bound by a sampled match (§e.6). <!-- F7 -->
5. **Unclear roles**: `isPlayable` (fact or verdict?), `masterLocation` (free text), `backupDestinations` (still
   used beside attestations?), `workspaceActive`, `needsReformat` (file or content?). *Recommend:* carry verbatim,
   decide after cutover; none gates a delete.
6. **New in r2, two small calls.**
   (a) `auditChanged` is classed as a *finding* reason: a byte match by the old digest does not resolve it. The
   rule that clears it is "the rescan at the same path yields the recorded digest", i.e. only the metadata
   changed.
   (b) Derived values import `unverified` because none carries a stat stamp (§e.8). A time-window rule could
   upgrade some of them; *recommend not: regenerate instead.* <!-- F5 F9 -->
