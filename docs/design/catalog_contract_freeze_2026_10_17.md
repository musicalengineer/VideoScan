# Catalog contract freeze — step B (2026-10-17)

Status: DESIGN, read-only. Brief: `docs/briefs/cloud/CONTRACT_FREEZE.md`. Plan: `catalog_sqlite_migration_2026_10_16.md`
§10 (v3: verify once → import the verified rows → rescan by digest → cutover); `integrity_first_2026_10_16.md`
§2–§3a. Schema: `catalog_sqlite_schema_v1.sql` (same branch). GH #328. Read from source (no Swift toolchain); every writer is a
grep-and-read citation. The DDL was loaded into
SQLite 3.45 and 20 refusal cases were exercised against it (duplicate live path, `v1:` digest, revision going down,
supersession cycle, ledger UPDATE / `INSERT OR REPLACE`, generation skip, lossy import line, …): all refused.

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
| 53 | pairedWithID (`pendingPairedWithID`, `pairedWith`) | UUID? | P | L | `A/MediaOps/VideoScanModel+Correlate.swift:55,174,221`; `A/MediaOps/CorrelationScorer.swift:147`; resolve CatalogStore:820; `A/Volumes/VideoScanModel+ScanMerge.swift:512` | T:av_pairs |
| 54 | pairGroupID | UUID? | P | L | Correlate:56,175; ScanMerge:513; CatalogStore:823 | T:av_pairs (kept: events cite `pair:`) |
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
| 125 | footageDecisions | [FootageDecision] | N | C | `C/FootageMembership.swift:204–209` via FindSimilarFootage:351–355; R relink :652 | T:footage_decisions |
| 126 | familyMusic | FamilyMusicInfo? | P | C | `A/FamilyMusic/VideoScanModel+FamilyMusic.swift:35,55` | T:family_music |
| 127 | perceptualFingerprint | StoredPerceptualFingerprint? | P | S bound (size + recipe) | `A/Media/VideoScanModel+PerceptualFingerprints.swift:99,109,133`; R:492 (size match) | T:perceptual_prints |
| 128 | mediaReportCard | MediaReportCard? | P | S unbound | CM:270; MediaRepairJob:212,256 | media_checks `reportCard` |
| 129 | audioFingerprint | AudioFingerprintStamp? | P | S bound (`contentDigest`) | `A/MediaOps/VideoScanModel+AudioFingerprintBackfill.swift:48,58` ← AudioFingerprintBackfillJob:541 | T:sound_prints (sha256-keyed only) |

**Roll-up** (one role per row): D 41 · S 39 · C 14 · L 13 · B 11 · V 7 · unclear 4 = 129. **Lost on a rescan
today** (no R): every verify field, `contentFixity`, `audioFingerprint`, `mediaReportCard`, `archivedAt`,
`needsReformat`, `backupDestinations`, `junkReasons`, `workspaceActive`, all pair/dup/avid/trim/cleanup fields — the
SHA-256 among them, which is exactly why §10 keys knowledge by digest instead of trusting rescan preservation.
**Unbound stamps** (no content digest today, so tier 4 cannot check them): captions, transcripts, OCR, dossier,
inferred dates, faces, junk, verify verdicts, report card. Keying their tables by digest makes them bound by
construction (§e).

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
| `FootageDecision` `C/FootageMembership.swift:171` | otherID (a ROW id), verdict (same / notSame), decidedAt | C | `footage_decisions` as a digest pair |
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
| `ignored-content.json` | `IgnoredContentFile {entries:[{id, partialMD5, sizeBytes, filename, reason, addedAt, samplePath}]}` `A/Catalog/IgnoredContentStore.swift:76,109` | (partialMD5, size); fallback (filename, size) — **sampled** | `saveOffMain` :338 | `ignored_content` (Q4) |
| `catalog-audit.json` | `CatalogAuditRunRecord {startedAt, finishedAt?, outcome, partial, counts, marked}` `A/MediaOps/CatalogAuditRun.swift:25` | none — **no per-row result** | `CatalogAuditRunMarker.persist` :132 | `job_markers` (job=audit) |
| `fullhash-backfill.json` | `{startedAt, finishedAt?, hashedSoFar}` `A/MediaOps/FullHashBackfillResume.swift:26` | none | `persist` :99 (MOPS-13) | `job_markers` (job=fullHash) |
| sound-print backfill | no resume file (`A/MediaOps/AudioFingerprintBackfill.swift:18`) | — | — | — |
| freshness stamps | not persisted separately; per-row stamps + the two markers above (`A/Analyze/AnalyzeCoverage.swift:1–27`) | — | — | the stamps' tables + `job_markers` |
| `integrity-latest.json`, `integrity-<date>.json` | `IntegrityReport` schema 2 `A/Integrity/IntegrityReport.swift:146`: run, generations, catalogSHA256, tiers, findings ≤ 5,000 (:151) | tier int; findings by **record UUID** (:136) | `IntegrityReportStore.write` :289 (MOPS-15) | `integrity_runs`; files stay as the dated history |
| `ledger/media-ledger.jsonl` | `MediaLedgerEvent {at, event, recordID, contentKey, filename, fullPath, by, batchID?, detail}` `C/MediaLedgerEvent.swift:31`, 18 kinds :35 | recordID + `contentKey` = `h:`+**v1 contentHash** or `p:md5:size` (:183) + path | `MediaLedger.append` `A/Archive/MediaLedger.swift:102` (O_APPEND + fsync) | `ledger` (append-only) + the JSONL kept |
| `audio-fingerprints.sqlite` | `fingerprints(content_digest, size_bytes, engine_version, …, blob)` PK the three, `C/AudioFingerprintStore.swift:177–204` | self-describing digest (`sha256:` or `v1:`) + size | `put` :262 | stays its own DB (§9b); bound through `sound_prints.sidecar_key` |
| `catalog.generation.max` | one integer | none | `A/Catalog/CatalogGenerationSidecar.swift` via CatalogStore:510,552,792 | `catalog_state.generation_high_water` |
| `date-inference/unwound-*.json` | `UnwoundDateSidecar` (DI:1099) | recordID + fullPath (DI:1075) | DI:1285 | stays (undo history) |
| `archive-angel/evidence.json` | `[UUID: ArchiveAngelEvidenceRecord]` | record UUID | `ArchiveAngelEvidenceStore.saveOffMain` :473 | rebuildable cache — not imported |
| `delete-duplicates/<plan>/plan.json` | targets: path + recordID? (`A/MediaOps/DeleteDuplicatesPlan.swift:89–172`) | path | rewritten per pair | import gate: **no open plan** |
| `media-person-links.json` | `{personID, mediaHash (partialMD5), mediaPath, source, notedAt}` `A/Media/MediaPersonLinks.swift:144` | (personID, **partialMD5**) | — | out of the catalog; Q4 |
| `cyberbrain/cyberbrain.json` | people knowledge; photo captions cite **absolute path** | person id | `C/CyberBrainWriter*.swift` | out of scope; path-keyed (Q4) |
| `metadata_cache.sqlite`, `catalog.search-index.v1.plist` | probe cache, search index | path | — | rebuildable, not imported |

## d. Invariants → engine or job

`Integrity/CatalogConstraints.swift` holds **14** rules (`Rule` :142–155): 13 are tier 5, `derivedStampsMatchContent`
is tier 4 (:160). All 14 map:

| # | Rule | SQLite | Kind |
|---|---|---|---|
| 1 | uniqueIDs | `files.id` PK; `quarantine_one_per_json_row`; a duplicated JSON id quarantines every carrier | PK |
| 2 | oneLiveRowPerPath | `files_live_path` UNIQUE (volume_uuid, full_path) WHERE live | partial UNIQUE |
| 3 | lineageTargetsExist | `lineage`, `supersessions` FK → `content` RESTRICT; `archive_copies.source_file_id` FK → `files`; rows never deleted | FK |
| 4 | promotionsHaveASource | `archive_copies_need_source` (only `promoted_by='import'` may carry NULL, with its finding) | trigger |
| 5 | removalMirrorsLifecycle | CHECK `removal_state IS NOT 'inTrash' OR lifecycle='Trashed'` | CHECK |
| 6 | requiredFields | NOT NULL; CHECK path non-blank and absolute; `size_bytes >= 0` | CHECK |
| 7 | wholeFileDigestsAreWhole | `content.digest` CHECK 64 lower hex; `files.content_digest` FK; `sampled_hash GLOB 'v1:*'` in its own column; size = byte_count trigger | CHECK + FK + trigger |
| 8 | removalRevisionNonNegative | CHECK ≥ 0; `files_removal_revision_monotonic`; `files_removal_change_bumps_revision` | CHECK + trigger |
| 9 | auditStampNamesItsVolume | CHECK non-blank; stamp ⇔ seen_at; `files_path_change_clears_audit_stamp` (= `C/VideoRecord.swift:140`) | CHECK + trigger |
| 10 | eventMembersExist | `event_members.digest` FK | FK |
| 11 | pathAliasByCase | **stays a finding** (a case-sensitive volume may hold both); `files_case_folded` index makes it O(log n) | job, no I/O |
| 12 | supersessionCycle | `supersessions_acyclic` (recursive CTE) + `supersessions_no_rewrite` | trigger |
| 13 | duplicateGroupDigestsAgree | `duplicate_members_one_digest` + `files_digest_immutable` | trigger |
| 14 | derivedStampsMatchContent (tier 4) | structural: every stamp table's key IS the digest it was made from; a changed file is a new row with a new digest | retired by the key |

**MOPS** (`docs/practices/invariants/MediaOps.md`). Need I/O → **stay jobs**: MOPS-1/2 (prove a surviving copy at
delete time, nothing from a cache), 4/5 (no clobber; sources untouched), 7 (catalog and disk agree per item — one
transaction per item), 8 (path inside its volume, no links), 10, 11 (`MediaTrash.move`), 12 (receipt CSV stays a
file). Engine support: rows never deleted (tombstones); MOPS-3 → `archive_copy_never_trashed`; MOPS-6 (the record
follows only a verified copy) → `files_digest_immutable` + the size trigger, so a moved path must carry the same
content; MOPS-9 → the sink + `ledger`; MOPS-13 → `job_markers`; MOPS-14 → removal triggers + audit-stamp CHECK and
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
3. Every knowledge table (§6 of the DDL) is keyed by digest → two byte-identical files share one star / date /
   people list (Q1), and a rescanned file at a new path re-attaches without any id or path match.
4. A file whose bytes change is a NEW row (`files_digest_immutable`); the old content's knowledge stays on the old
   digest — never silently carried onto other bytes.
5. Archive promotion copies bytes, so the archive copy and its source share a digest: promotion is file → file
   (`archive_copies`), not content lineage. Derivatives (trim, repair, …) are other bytes: `lineage` digest → digest.
6. Sound prints: only `sha256:`-keyed stamps import. Ledger, ignored list, person links and v1 prints carry sampled
   keys: they import verbatim, never as identity, and rebind to a digest only through a row that has one (Q4).
7. Knowledge whose writer named a ROW (`inferredDateSource = "propagated from <uuid>"`, `FootageDecision.otherID`,
   events `id:`) is translated to digests at import through that row's digest; when the row has none, the item is
   listed with the row in quarantine.

## f. Importer gate (§10a D′)

**Inputs**: `catalog.json` (frozen read-only first, then SHA-256'd), `integrity-latest.json`, `catalog-audit.json`,
`events-decisions.json`, `ignored-content.json`, `ledger/media-ledger.jsonl`.

**Run-level refusals** (nothing is written): JSON version > 6; integrity report `outcome ≠ completed`, or
`catalogHashCertified = false`, or `catalogSHA256 ≠` the frozen file's hash, or `snapshotGeneration ≠` the file's
generation; `findingsTotal > findings.count` (findings capped at 5,000 — a truncated list cannot gate rows; rerun
after fixing); tiers 0, 1 or 5 `notRun`; `catalog-audit.json` missing, `partial`, outcome ≠ completed, or finished
after the integrity run started; any open `delete-duplicates/` plan or Archive Angel batch; the app or the headless
audit running (one writer).

**Per-row inputs.** *Audit* — tier 0 has no per-row findings (`A/Integrity/VerifyCatalogTiers.swift:133–173`, counts
only), so "seen" is derived: `auditSeenOn != nil` AND `seenAt ≥` the audit run's `startedAt` AND the importer's own
read-only stat (one `lstat`, no open) agrees with `sizeBytes` and the fixity stamp's inode / mtime / ctime (the
`describesFileNow` rule) (Q3). Results: **seen** / **gone** (ENOENT on a mounted volume) / **never seen** (no stamp
from this run) / **could not check** (volume not mounted, link in path, other errno) / **changed** (stat ≠ stamp).
*Digest* — `storedFullDigest(r) != nil`, and when both fixities exist they agree. *Tier 5* — any finding with this
`recordID` and `needsDecision`. *Marker* — `removal` state or nil.

| Marker | Audit | Digest | Tier-5 finding | → | Reason code / words |
|---|---|---|---|---|---|
| nil | seen | yes | none | **main** | — |
| nil | seen | yes | tier-4 only (stale print) | **main**, stale stamp not imported | listed in the import report |
| nil | seen | yes | any tier 5 | quarantine | `tier5Finding` — the finding's own words |
| nil | seen | no | — | quarantine | `noWholeFileDigest` — "on disk, but its identity was never read in full; Fill In Full Hashes, then rescan" |
| nil | gone | any | — | quarantine | `auditGone` — "not at its path when last checked" |
| nil | never seen | any | — | quarantine | `auditNeverSeen` — "no audit has seen this file — Fix Links decides" |
| nil | could not check | any | — | quarantine | `auditCouldNotCheck` — "its drive was not connected (or a link is in the path)" |
| nil | changed | any | — | quarantine | `auditChanged` — "the file changed since its identity was read" |
| set | (not asked) | yes | none | **main, as a tombstoned row** (marker + revision kept; history for lineage and archive sources) | — |
| set | (not asked) | yes | any | quarantine | `tier5Finding` |
| set | (not asked) | no | — | quarantine | `removedNoDigest` — "left the catalog before its identity was read; kept as history" |
| any | any | fixities disagree | — | quarantine | `fixityDisagree` |
| any | any | any | uniqueIDs | quarantine (every carrier) | `duplicateId` |

A main row whose live path collides with another main row (rule 2) is caught as a tier-5 finding first; the UNIQUE
index is the backstop. **Knowledge**: for every row with a digest — main or quarantined — `content` gets the digest and
the knowledge tables get its curated and derived fields (Q2 for conflicts); rows without a digest keep theirs only in
`quarantine.raw_row`. Lineage / supersession / archive-source references to a quarantined row: the `lineage` and
`supersessions` rows go in when both ends have digests; `archive_copies.source_file_id` stays NULL with the finding
when the source is quarantined (`promoted_by='import'`). Events: members resolve `sha256` → digest, `pair:` → both
halves' digests, `id:` → that row's digest; unresolvable members are listed against their row.

**Reconciliation line** (one `import_runs` row, CHECK enforced, and one OUTCOME line through the sink):
`rows before N · main M (live L, tombstoned T) · quarantine Q (by reason …) · digests D · knowledge rows K (by table)
· events E (members resolved / listed) · ledger lines J`, with `N = M + Q` or no commit.

**Comparator** (independent: re-decodes `catalog.json` by its own path, reads SQLite by SQL): every JSON row id is
exactly once in `files.id` ∪ `quarantine.json_row_id`; every distinct whole-file digest in the JSON is in `content`;
every curated value (fields 41, 42, 64, 70, 73, 74, 106–110, 119, 125, 126) is present by digest or in `raw_row`;
every event member key, every ledger line and every ignored entry is accounted for. Any miss → ROLLBACK, the
SQLite file is deleted, the report names the miss. The import is one transaction; the JSON is never written.

## g. Reconciliation by digest — the rescan (§10a E′)

Per mounted volume, per media file: (1) **still-being-written rule** (A′ adds it; no such rule exists in the code
today): two `lstat`s ≥ 30 s apart must agree on size and mtime and the mtime must be ≥ 2 min old; then hash; then
`lstat` again — the stamp must equal the first. Any disagreement → not catalogued this run, listed (`stillBeingWritten`,
deferred; never a row, never a quarantine resolution). (2) ffprobe + whole-file SHA-256 bound to the stat stamp.
(3) Decide:

| Case | Action |
|---|---|
| live row at (volume, path) with the same digest | refresh disk facts + stamp; nothing else |
| live row at (volume, path) with a **different digest** (the file was replaced) | old row → removal `removedFromCatalog`, reason `replacedAtPath` (a new `RemovalReason`), tombstone row; NEW row for the new digest; knowledge stays with the old digest; listed |
| **known digest at a new path**, and exactly one live row with that digest is proven gone from its own path (the audit's proof rule) | that row's path is updated (keeps its id; the trigger clears the audit stamp); knowledge was never path-bound |
| known digest at a new path, its other rows still present (or several gone) | new row (a copy); knowledge shared by digest; gone candidates left to the audit |
| digest of an open **quarantined** row | new `files` row (reusing `json_row_id` as `id` when free, so ledger and `id:` references resolve); file-level fields from `raw_row` (lifecycle, archive stage, notes; a `missing` marker is cleared — it was found); `quarantine.resolved_* = foundByDigest`; knowledge is already there by digest |
| **new digest** | new `content` + `files` rows; no knowledge |
| quarantined row never found | stays open with its words — history, never deleted |
| quarantined row with no digest whose sampled hash + size + name match a new file | offered to Rick as a candidate (`personDecided`), never automatic |

Rescan reconciliation line: `walked · in place · moved · copies · replaced · quarantine resolved · new · deferred ·
unreadable`; live rows on the volume the walk did not see are NOT marked by the rescan — the audit owns "gone".

## h. Open questions for Rick (5)

1. **Curated knowledge per content, not per file.** Keying stars, notes, tags, disposition, date, place, people by
   digest means two byte-identical copies always agree (today they can differ). *Recommend: yes — it is the §10 rule,
   and Promote already propagates these onto the archive copy (MA:1312–1344).*
2. **Conflicts at import** when rows with one digest disagree (two different hand dates on two copies).
   *Recommend:* sets (people, tags, attestations, footage verdicts) union, except a `rejected` name removes the same
   `confirmed`/`detected` name; scalars: `known` beats `estimated`, then the latest `dateSet` / `placeSet` ledger line
   for those rows, then the archive copy's value; anything still tied is listed for you and the field left empty
   until you choose — never picked silently.
3. **Per-row audit evidence.** Tier 0 records counts only; the gate needs per-row "seen / gone / changed".
   *Recommend:* the importer does its own read-only `lstat` per row against the fixity stamp (§f) — no media opened,
   MOPS-14's walk reused — rather than adding per-row output to `catalog-audit.json` this late in A′.
4. **Stores keyed by sampled hashes** — `ignored-content.json` (partialMD5+size), `media-person-links.json`
   (partialMD5), ledger `contentKey` (`h:v1…`), `v1:` sound prints. *Recommend:* import verbatim, never as identity;
   the rescan hashes ignored files too and binds each entry to a digest only when exactly one hashed file matches;
   `v1:` prints are recomputed; person links move into a digest-keyed table in step G.
5. **Fields whose role is unclear**: `isPlayable` (a word from ffprobe — fact or verdict?), `masterLocation` (free
   text beside the Master Archive designation), `backupDestinations` (manual "backed up to" list; is it still used
   next to attestations?), `workspaceActive` and `needsReformat` (file state or content property?).
   *Recommend:* carry all five verbatim (columns / `probe_extra` / `backup_destinations`) and decide after the
   cutover; none of them gates a delete.
