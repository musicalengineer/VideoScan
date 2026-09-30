# Periphery dead-code scan — 2026-09-22

Periphery 3.8.0, Xcode 27.0 (27A266a), Swift 6.4, M4. Source: detached worktree at main `39956d86`. Scheme `VideoScan`, Debug, index built by `xcodebuild build-for-testing` into `/private/tmp/dd-periphery`, then `periphery scan --skip-build --index-store-path`. Config `.periphery.yml` (retain_objc_accessible, retain_unused_protocol_func_params, retain_public=false) plus `--retain-swift-ui-previews`. Read-only; no source changed.

Note: periphery 3.8 always injects its own `-derivedDataPath`, so passing another after `--` makes xcodebuild fail with exit 64 ("may only be provided once"). Building separately and scanning with `--skip-build` works around it.

## Totals by kind

| Run | unused declaration | assign-only property | unused parameter | redundant public | total | in test files |
|---|---:|---:|---:|---:|---:|---:|
| A: default (tests indexed) | 295 | 363 | 54 | 17 | 729 | 68 |
| B: A + --retain-codable-properties | 271 | 233 | 54 | 17 | 575 | 52 |
| C: --exclude-tests | 644 | 486 | 47 | 30 | 1207 | 0 |

Run C minus run A: about 478 production declarations are referenced **only from tests**. Run A minus run B: 154 assign-only properties sit on Codable types (encoder reads them), so they are false positives.

## Top files (run B)

| Findings | File |
|---:|---|
| 20 | VideoScan/AvbParser.swift |
| 16 | VideoScanCore/Sources/VideoScanCore/PreviewSweepCLIOptions.swift |
| 11 | VideoScan/CopyFamilyAssessor.swift |
| 10 | VideoScan/ArchivistChatWindow.swift |
| 10 | VideoScan/CatalogHelpers.swift |
| 10 | VideoScan/FamilyKinshipInference.swift |
| 8 | VideoScan/CatalogToolbar.swift |
| 8 | VideoScan/TreeIdentityCenter.swift |
| 7 | VideoScan/PersonFinderCompilation.swift |
| 7 | VideoScanCore/Sources/VideoScanCore/PreviewCacheFormat.swift |
| 7 | VideoScanCore/Sources/VideoScanCore/PreviewHelperSupervisor.swift |
| 6 | VideoScan/ArchivistGraphExecutor.swift |
| 6 | VideoScan/ArchivistTemporalExecutor.swift |
| 6 | VideoScan/HallieTurnExecutor+Conversation.swift |
| 6 | VideoScanCore/Sources/VideoScanCore/PrunePlan.swift |
| 6 | VideoScanCore/Sources/VideoScanCore/UnplayableLegacyCodecs.swift |
| 6 | VideoScanCore/Sources/VideoScanCore/WorldKnowledge.swift |
| 5 | VideoScan/DossierDashboardView+FleetStats.swift |
| 5 | VideoScan/FamilyTreeCards.swift |
| 5 | VideoScanCore/Sources/VideoScanCore/LineageTrail.swift |

## Full output: run A (default). Items marked `C` are suppressed by --retain-codable-properties

```
  unused parameter       var.parameter                cancelled                                          VideoScan/AnalyzeJob.swift:341:25
  unused declaration     function.method.instance     reset()                                            VideoScan/ArcFaceEngine.swift:169:10
  unused parameter       var.parameter                total                                              VideoScan/ArcFaceEngine.swift:609:17
  unused parameter       var.parameter                index                                              VideoScan/ArcFaceEngine.swift:609:5
C unused declaration     var.instance                 isEmpty                                            VideoScan/ArchiveAngelAttention.swift:58:9
  unused declaration     var.static                   machineNotePrefixes                                VideoScan/ArchiveAngelCandidate+Record.swift:145:28
  unused declaration     var.static                   ffmpegLogHeader                                    VideoScan/ArchiveAngelCandidate+Record.swift:150:28
  assign-only property   var.instance                 revision                                           VideoScan/ArchiveAngelCatalogBadge.swift:37:9
  unused declaration     function.method.static       chipColor(_:)                                      VideoScan/ArchiveAngelDetailView.swift:151:17
  unused declaration     function.method.static       icon(_:)                                           VideoScan/ArchiveAngelDetailView.swift:412:17
  unused declaration     function.method.static       background(_:)                                     VideoScan/ArchiveAngelDetailView.swift:421:17
C assign-only property   var.instance                 useCount                                           VideoScan/ArchiveAngelEvidenceStore.swift:59:9
C assign-only property   var.instance                 lastUsed                                           VideoScan/ArchiveAngelEvidenceStore.swift:60:9
C assign-only property   var.instance                 computedAt                                         VideoScan/ArchiveAngelEvidenceStore.swift:61:9
C assign-only property   var.instance                 sourceModifiedAt                                   VideoScan/ArchiveAngelPlan.swift:103:13
C assign-only property   var.instance                 makeLossless                                       VideoScan/ArchiveAngelPlan.swift:217:9
C unused declaration     var.instance                 skippedEntries                                     VideoScan/ArchiveAngelPlan.swift:249:9
  unused declaration     function.method.instance     noteInteraction()                                  VideoScan/ArchiveAngelSweep.swift:162:10
  unused declaration     module                       VideoScanCore                                      VideoScan/ArchiveDateEntry.swift:24:1
  assign-only property   var.instance                 persistedViewMode                                  VideoScan/ArchiveHomeState.swift:75:9
C assign-only property   var.instance                 at                                                 VideoScan/ArchivePromoteDecisions.swift:22:13
C assign-only property   var.instance                 recordID                                           VideoScan/ArchivePromoteDecisions.swift:23:13
C assign-only property   var.instance                 filename                                           VideoScan/ArchivePromoteDecisions.swift:24:13
C assign-only property   var.instance                 sourcePath                                         VideoScan/ArchivePromoteDecisions.swift:25:13
C assign-only property   var.instance                 decision                                           VideoScan/ArchivePromoteDecisions.swift:26:13
C assign-only property   var.instance                 reason                                             VideoScan/ArchivePromoteDecisions.swift:27:13
C assign-only property   var.instance                 detail                                             VideoScan/ArchivePromoteDecisions.swift:28:13
  unused declaration     function.method.static       all(rootPath:)                                     VideoScan/ArchivePromoteDecisions.swift:53:29
  unused declaration     function.method.static       of(path:)                                          VideoScan/ArchivePromoteEngine.swift:148:21
C unused declaration     var.instance                 isPublished                                        VideoScan/ArchivePromoteEngine.swift:814:17
C assign-only property   var.instance                 at                                                 VideoScan/ArchivePromoteEngine.swift:822:13
  assign-only property   var.instance                 container                                          VideoScan/ArchiveReadiness.swift:50:13
  assign-only property   var.instance                 audioChannels                                      VideoScan/ArchiveReadiness.swift:54:13
  assign-only property   var.instance                 audioSampleRate                                    VideoScan/ArchiveReadiness.swift:55:13
  assign-only property   var.instance                 durationSeconds                                    VideoScan/ArchiveReadiness.swift:56:13
  assign-only property   var.instance                 version                                            VideoScan/ArchiveView+Categories.swift:235:9
  assign-only property   var.instance                 volumeSearchPaths                                  VideoScan/ArchiveView+Categories.swift:236:9
  unused declaration     var.instance                 phrase                                             VideoScan/ArchivistAgePhrase.swift:24:13
  unused declaration     var.instance                 ollamaHost                                         VideoScan/ArchivistAskField.swift:35:53
  unused parameter       var.parameter                fileManager                                        VideoScan/ArchivistBiographyPhoto.swift:21:9
  assign-only property   var.instance                 profileStableID                                    VideoScan/ArchivistBiographyPhoto.swift:8:9
  unused declaration     function.method.instance     handleGeneralQuestion(_:)                          VideoScan/ArchivistChatWindow.swift:1668:18
  unused declaration     function.method.instance     declineForRecompile(original:)                     VideoScan/ArchivistChatWindow.swift:1715:18
  unused declaration     function.method.instance     answerDate(personText:wantsBirth:original:)        VideoScan/ArchivistChatWindow.swift:1729:18
  unused declaration     function.method.instance     answerPlace(personText:wantsBirth:original:)       VideoScan/ArchivistChatWindow.swift:1756:18
  unused declaration     function.method.instance     answerWhoIs(personText:original:)                  VideoScan/ArchivistChatWindow.swift:1780:18
  unused declaration     function.method.instance     appendProfileAmbiguity(_:typedName:original:playAfterAnswer:) VideoScan/ArchivistChatWindow.swift:1802:18
  unused declaration     function.method.instance     handleKinship(_:)                                  VideoScan/ArchivistChatWindow.swift:1887:18
  unused parameter       var.parameter                label                                              VideoScan/ArchivistChatWindow.swift:2245:51
  unused parameter       var.parameter                matches                                            VideoScan/ArchivistChatWindow.swift:2260:42
  unused declaration     var.instance                 ollamaHost                                         VideoScan/ArchivistChatWindow.swift:246:53
  assign-only property   var.instance                 fullPath                                           VideoScan/ArchivistFollowUpResolver.swift:20:17
  assign-only property   var.instance                 effectiveGEDCOMPersonID                            VideoScan/ArchivistGraphExecutor.swift:382:13
  assign-only property   var.instance                 label                                              VideoScan/ArchivistGraphExecutor.swift:399:17
  assign-only property   var.instance                 canonicalName                                      VideoScan/ArchivistGraphExecutor.swift:774:13
  assign-only property   var.instance                 aliases                                            VideoScan/ArchivistGraphExecutor.swift:775:13
  assign-only property   var.instance                 treeIdentity                                       VideoScan/ArchivistGraphExecutor.swift:779:13
  assign-only property   var.instance                 treeIdentityUnreadable                             VideoScan/ArchivistGraphExecutor.swift:780:13
  unused declaration     enumelement                  left                                               VideoScan/ArchivistLivingPortrait.swift:65:22
  assign-only property   var.instance                 profileStableID                                    VideoScan/ArchivistProfileGallery.swift:14:9
  assign-only property   var.instance                 profileCanonicalName                               VideoScan/ArchivistProfileGallery.swift:15:9
C assign-only property   var.instance                 operation                                          VideoScan/ArchivistQueryAST.swift:175:13
C assign-only property   var.instance                 operation                                          VideoScan/ArchivistQueryAST.swift:93:13
  assign-only property   var.instance                 asked                                              VideoScan/ArchivistRecordExecutor.swift:127:13
  assign-only property   var.instance                 frameRate                                          VideoScan/ArchivistRecordExecutor.swift:37:9
  assign-only property   var.instance                 userDate                                           VideoScan/ArchivistRecordExecutor.swift:41:9
  assign-only property   var.instance                 embeddedCreationDate                               VideoScan/ArchivistRecordExecutor.swift:42:9
  unused declaration     var.instance                 recordID                                           VideoScan/ArchivistTemporalExecutor.swift:119:9
  unused parameter       var.parameter                subjects                                           VideoScan/ArchivistTemporalExecutor.swift:1295:9
  assign-only property   var.instance                 canonicalName                                      VideoScan/ArchivistTemporalExecutor.swift:276:9
  assign-only property   var.instance                 birthdate                                          VideoScan/ArchivistTemporalExecutor.swift:277:9
  assign-only property   var.instance                 birthdateProvenance                                VideoScan/ArchivistTemporalExecutor.swift:278:9
  unused parameter       var.parameter                name                                               VideoScan/ArchivistTemporalExecutor.swift:636:61
  assign-only property   var.instance                 looper                                             VideoScan/ArchivistVideoPortrait.swift:75:17
  unused declaration     var.instance                 showDetails                                        VideoScan/AssessCopiesDetailView.swift:38:24
  assign-only property   var.instance                 creationDate                                       VideoScan/AvbParser.swift:24:9
  assign-only property   var.instance                 objectIndex                                        VideoScan/AvbParser.swift:251:9
  assign-only property   var.instance                 lastModified                                       VideoScan/AvbParser.swift:25:9
  unused declaration     function.method.instance     bool(_:)                                           VideoScan/AvbParser.swift:264:10
  assign-only property   var.instance                 duration                                           VideoScan/AvbParser.swift:27:9
  assign-only property   var.instance                 descriptorType                                     VideoScan/AvbParser.swift:31:9
  assign-only property   var.instance                 startPos                                           VideoScan/AvbParser.swift:39:9
  assign-only property   var.instance                 sourceClipMobID                                    VideoScan/AvbParser.swift:41:9
  assign-only property   var.instance                 sourceTrackID                                      VideoScan/AvbParser.swift:42:9
  assign-only property   var.instance                 filePath                                           VideoScan/AvbParser.swift:47:9
  assign-only property   var.instance                 creatorVersion                                     VideoScan/AvbParser.swift:49:9
  assign-only property   var.instance                 lastSave                                           VideoScan/AvbParser.swift:50:9
  unused parameter       var.parameter                isLE                                               VideoScan/AvbParser.swift:613:72
  unused parameter       var.parameter                readObj                                            VideoScan/AvbParser.swift:614:35
  unused parameter       var.parameter                readObj                                            VideoScan/AvbParser.swift:654:43
  unused declaration     var.instance                 remaining                                          VideoScan/AvbParser.swift:68:9
  unused declaration     var.instance                 isAtEnd                                            VideoScan/AvbParser.swift:69:9
  unused parameter       var.parameter                readObj                                            VideoScan/AvbParser.swift:800:47
  unused declaration     function.method.instance     readS8()                                           VideoScan/AvbParser.swift:85:10
  unused parameter       var.parameter                readObj                                            VideoScan/AvbParser.swift:864:42
  assign-only property   var.instance                 path                                               VideoScan/BundleExporter.swift:62:13
C assign-only property   var.instance                 version                                            VideoScan/BundleModels.swift:83:9
C assign-only property   var.instance                 savedAt                                            VideoScan/BundleModels.swift:84:9
C unused declaration     var.instance                 version                                            VideoScan/BundleModels.swift:93:9
C assign-only property   var.instance                 savedAt                                            VideoScan/BundleModels.swift:94:9
  assign-only property   var.instance                 transcriptFailed                                   VideoScan/CaptionPipelineTypes.swift:134:9
  unused declaration     var.instance                 isInFlight                                         VideoScan/CaptionPipelineTypes.swift:43:9
  assign-only property   var.instance                 verb                                               VideoScan/CaptionPipelineTypes.swift:74:9
  unused declaration     function.method.instance     prewarm()                                          VideoScan/CaptionRunner.swift:461:10
  assign-only property   var.instance                 pythonPath                                         VideoScan/CaptionRunner.swift:779:9
  assign-only property   var.instance                 scriptPath                                         VideoScan/CaptionRunner.swift:782:9
  unused declaration     var.instance                 checkedAt                                          VideoScan/CatalogHealthReport.swift:11:9
  assign-only property   var.instance                 volumePath                                         VideoScan/CatalogHealthReport.swift:8:9
  assign-only property   var.instance                 onShowPair                                         VideoScan/CatalogHelpers.swift:101:9
  assign-only property   var.instance                 selectedID                                         VideoScan/CatalogHelpers.swift:226:13
  assign-only property   var.instance                 version                                            VideoScan/CatalogHelpers.swift:227:13
  assign-only property   var.instance                 analyzing                                          VideoScan/CatalogHelpers.swift:228:13
  assign-only property   var.instance                 version                                            VideoScan/CatalogHelpers.swift:232:13
  assign-only property   var.instance                 purge                                              VideoScan/CatalogHelpers.swift:233:13
  assign-only property   var.instance                 tidy                                               VideoScan/CatalogHelpers.swift:234:13
  assign-only property   var.instance                 selectedID                                         VideoScan/CatalogHelpers.swift:259:13
  assign-only property   var.instance                 version                                            VideoScan/CatalogHelpers.swift:260:13
  assign-only property   var.instance                 previewFilename                                    VideoScan/CatalogHelpers.swift:87:9
C assign-only property   var.instance                 acquiredAt                                         VideoScan/CatalogLock.swift:49:9
  assign-only property   var.instance                 count                                              VideoScan/CatalogPerfMemo.swift:26:9
  assign-only property   var.instance                 revision                                           VideoScan/CatalogPerfMemo.swift:27:9
  unused declaration     function.free                pfPurgedRecords(_:)                                VideoScan/CatalogQueries.swift:781:18
  unused declaration     var.instance                 totalTooltip                                       VideoScan/CatalogSizeTotals.swift:249:9
  unused declaration     struct                       CatalogSizeTotalsBox                               VideoScan/CatalogSizeTotals.swift:273:8
  assign-only property   var.instance                 partialMD5                                         VideoScan/CatalogSnapshot.swift:53:9
  assign-only property   var.instance                 duplicateGroupID                                   VideoScan/CatalogSnapshot.swift:64:9
  assign-only property   var.instance                 combinedFromPairID                                 VideoScan/CatalogSnapshot.swift:65:9
  unused declaration     var.static                   catalogAndPOI                                      VideoScan/CatalogSync.swift:126:16
  assign-only property   var.instance                 hostnameSource                                     VideoScan/CatalogSync.swift:305:17
  unused declaration     function.method.instance     stopViewerAutoRefresh()                            VideoScan/CatalogSync.swift:805:10
  unused declaration     var.instance                 openWindow                                         VideoScan/CatalogToolbar.swift:12:44
  unused declaration     var.instance                 showJunkConfirmSheet                               VideoScan/CatalogToolbar.swift:138:24
  unused declaration     var.instance                 showAskPopover                                     VideoScan/CatalogToolbar.swift:148:24
  assign-only property   var.instance                 sizeTotals                                         VideoScan/CatalogToolbar.swift:45:9
  assign-only property   var.instance                 dashboard                                          VideoScan/CatalogToolbar.swift:48:9
  assign-only property   var.instance                 onScanAvidBins                                     VideoScan/CatalogToolbar.swift:62:9
  assign-only property   var.instance                 avidBinCount                                       VideoScan/CatalogToolbar.swift:63:9
  assign-only property   var.instance                 avidBinFiles                                       VideoScan/CatalogToolbar.swift:64:9
  unused declaration     var.static                   figureGap                                          VideoScan/CatalogView+VolumeTable.swift:50:16
  unused declaration     function.method.static       shortBackupDest(_:)                                VideoScan/CatalogView+VolumeTable.swift:794:25
C assign-only property   var.instance                 at                                                 VideoScan/CatalogWriteError.swift:128:13
C assign-only property   var.instance                 detail                                             VideoScan/CatalogWriteError.swift:131:13
C assign-only property   var.instance                 processName                                        VideoScan/CatalogWriteError.swift:133:13
C assign-only property   var.instance                 hostname                                           VideoScan/CatalogWriteError.swift:134:13
  unused declaration     var.instance                 openWindow                                         VideoScan/CleanupSheet.swift:51:44
  unused declaration     var.instance                 substitutionsExpanded                              VideoScan/CombinePreflightSheet.swift:22:24
  unused declaration     var.instance                 blockedExpanded                                    VideoScan/CombinePreflightSheet.swift:23:24
  unused declaration     var.instance                 allChecked                                         VideoScan/CombineSheet.swift:57:17
  unused declaration     var.instance                 isActive                                           VideoScan/CompactDashboard.swift:16:17
  unused declaration     var.instance                 showSummary                                        VideoScan/ConfirmPersonSheet.swift:151:24
C unused declaration     var.instance                 prior                                              VideoScan/ConfirmRating.swift:68:9
  assign-only property   var.instance                 scrollView                                         VideoScan/ConsoleView.swift:66:13
  unused declaration     var.instance                 showCombineSheet                                   VideoScan/ContentView.swift:295:24
  unused declaration     var.instance                 showDashboard                                      VideoScan/ContentView.swift:324:24
  unused declaration     var.instance                 showInspector                                      VideoScan/ContentView.swift:325:24
  unused declaration     var.instance                 isOriginal                                         VideoScan/CopyFamilyAssessor.swift:146:9
  assign-only property   var.instance                 isRetired                                          VideoScan/CopyFamilyAssessor.swift:156:9
  assign-only property   var.instance                 isMasterArchive                                    VideoScan/CopyFamilyAssessor.swift:157:9
  assign-only property   var.instance                 audioCodec                                         VideoScan/CopyFamilyAssessor.swift:177:9
  assign-only property   var.instance                 container                                          VideoScan/CopyFamilyAssessor.swift:178:9
  assign-only property   var.instance                 resolution                                         VideoScan/CopyFamilyAssessor.swift:179:9
  assign-only property   var.instance                 frameRate                                          VideoScan/CopyFamilyAssessor.swift:180:9
  assign-only property   var.instance                 durationSeconds                                    VideoScan/CopyFamilyAssessor.swift:181:9
  unused declaration     var.static                   losslessAudioCodecs                                VideoScan/CopyFamilyAssessor.swift:242:16
  unused declaration     function.method.static       signatureKey(_:)                                   VideoScan/CopyFamilyAssessor.swift:539:17
  unused parameter       var.parameter                locations                                          VideoScan/CopyFamilyAssessor.swift:616:94
  unused declaration     function.method.static       bestCopy(from:)                                    VideoScan/CorrelationScorer.swift:513:17
  assign-only property   var.instance                 caption                                            VideoScan/CouplePortrait.swift:22:9
  unused declaration     function.method.static       candidates(in:)                                    VideoScan/CoverArtMusicPurge.swift:68:17
  unused declaration     function.method.instance     stopSystemMetrics()                                VideoScan/DashboardState.swift:484:10
  unused declaration     struct                       RecordDateInference                                VideoScan/DateTriangulation.swift:42:8
  unused declaration     extension.struct             RecordDateInference                                VideoScan/DateTriangulation.swift:48:11
  unused parameter       var.parameter                running                                            VideoScan/DeleteDuplicatesJob.swift:2222:37
  assign-only property   var.instance                 sizeBytes                                          VideoScan/DeleteDuplicatesPlan.swift:115:13
C unused declaration     var.instance                 isFinished                                         VideoScan/DeleteDuplicatesPlan.swift:592:9
C unused declaration     var.instance                 strandedEntries                                    VideoScan/DeleteDuplicatesPlan.swift:598:9
  unused declaration     function.method.static       checkCombine()                                     VideoScan/DependencyChecker.swift:59:17
C assign-only property   var.instance                 pathListsTruncated                                 VideoScan/DiscoveryAudit.swift:124:9
C assign-only property   var.instance                 scanRoot                                           VideoScan/DiscoveryAudit.swift:37:9
C assign-only property   var.instance                 volumeName                                         VideoScan/DiscoveryAudit.swift:39:9
C assign-only property   var.instance                 startedAt                                          VideoScan/DiscoveryAudit.swift:40:9
  unused declaration     var.instance                 color                                              VideoScan/DossierDashboardView+Coverage.swift:248:9
  unused declaration     var.static                   empty                                              VideoScan/DossierDashboardView+FleetStats.swift:135:16
  unused declaration     var.instance                 displayName                                        VideoScan/DossierDashboardView+FleetStats.swift:28:9
  unused declaration     var.instance                 color                                              VideoScan/DossierDashboardView+FleetStats.swift:44:9
  assign-only property   var.instance                 fileBytes                                          VideoScan/DossierDashboardView+FleetStats.swift:57:13
  unused declaration     var.instance                 aliveColor                                         VideoScan/DossierDashboardView+FleetStats.swift:97:13
  unused declaration     struct                       StageBadge_Removed                                 VideoScan/DossierDashboardView+Rows.swift:312:16
  assign-only property   var.instance                 now                                                VideoScan/DossierDashboardView+Rows.swift:387:9
  unused declaration     struct                       StatusBadge                                        VideoScan/DossierDashboardView+Subviews.swift:111:16
  unused declaration     struct                       DialRing                                           VideoScan/DossierDashboardView+Subviews.swift:20:16
  unused declaration     struct                       StatRow                                            VideoScan/DossierDashboardView+Subviews.swift:61:16
  unused declaration     function.method.instance     showInCatalog(filename:)                           VideoScan/DossierDashboardView.swift:550:18
  unused declaration     struct                       MiniRing                                           VideoScan/DossierToolbarChip.swift:107:16
  unused declaration     var.instance                 subText                                            VideoScan/DossierToolbarChip.swift:97:17
  unused declaration     var.instance                 severityKey                                        VideoScan/DriveHealth.swift:142:9
  unused declaration     var.instance                 sessionStart                                       VideoScan/DriveHealth.swift:246:17
  unused declaration     function.method.instance     invalidate(devicePath:)                            VideoScan/DriveHealth.swift:267:10
  unused declaration     function.method.instance     reset()                                            VideoScan/DriveHealth.swift:272:10
C assign-only property   var.instance                 mountPath                                          VideoScan/DriveHealth.swift:31:9
C assign-only property   var.instance                 devicePath                                         VideoScan/DriveHealth.swift:32:9
C assign-only property   var.instance                 reallocatedEvents                                  VideoScan/DriveHealth.swift:44:9
C assign-only property   var.instance                 dataWrittenBytes                                   VideoScan/DriveHealth.swift:49:9
  unused declaration     var.instance                 isIdle                                             VideoScan/ExpandedDashboard.swift:61:17
C assign-only property   var.instance                 notedAt                                            VideoScan/FamilyAssetStore.swift:1002:13
  assign-only property   var.instance                 overlayStamp                                       VideoScan/FamilyAssetStore.swift:136:13
  unused declaration     function.method.instance     documentURLs(for:)                                 VideoScan/FamilyAssetStore.swift:787:10
  assign-only property   var.instance                 first                                              VideoScan/FamilyKinship.swift:152:13
  assign-only property   var.instance                 second                                             VideoScan/FamilyKinship.swift:153:13
C unused declaration     var.instance                 asAnchor                                           VideoScan/FamilyKinship.swift:363:9
  unused declaration     function.method.static       ageWord(_:subjectBirth:anchorBirth:)               VideoScan/FamilyKinship.swift:502:17
  unused declaration     function.method.static       phrase(relation:anchorName:subjectSex:subjectBirth:anchorBirth:) VideoScan/FamilyKinship.swift:514:17
  assign-only property   var.instance                 basis                                              VideoScan/FamilyKinshipInference.swift:103:13
  assign-only property   var.instance                 from                                               VideoScan/FamilyKinshipInference.swift:111:13
  assign-only property   var.instance                 subject                                            VideoScan/FamilyKinshipInference.swift:161:13
  assign-only property   var.instance                 relation                                           VideoScan/FamilyKinshipInference.swift:350:43
  assign-only property   var.instance                 to                                                 VideoScan/FamilyKinshipInference.swift:350:74
  unused declaration     function.method.static       identity(of:overlay:)                              VideoScan/FamilyKinshipInference.swift:368:25
  unused declaration     function.method.instance     children(of:)                                      VideoScan/FamilyKinshipInference.swift:439:10
  unused declaration     function.method.instance     spouses(of:)                                       VideoScan/FamilyKinshipInference.swift:440:10
  assign-only property   var.instance                 from                                               VideoScan/FamilyKinshipInference.swift:843:32
  assign-only property   var.instance                 to                                                 VideoScan/FamilyKinshipInference.swift:843:48
  unused declaration     function.method.static       treeIdentity(_:graph:)                             VideoScan/FamilyKinshipOverlay.swift:1194:17
  assign-only property   var.instance                 outputURL                                          VideoScan/FamilySearchPersonRefresh.swift:101:9
C assign-only property   var.instance                 at                                                 VideoScan/FamilySearchPersonRefresh.swift:249:13
C assign-only property   var.instance                 source                                             VideoScan/FamilySearchPersonRefresh.swift:255:13
  assign-only property   var.instance                 request                                            VideoScan/FamilySearchPull.swift:166:9
  unused parameter       var.parameter                fileManager                                        VideoScan/FamilySearchPullCoordinator.swift:826:23
  unused declaration     var.instance                 showAdvanced                                       VideoScan/FamilySearchPullSheet.swift:25:24
  unused declaration     function.method.instance     stat(_:_:)                                         VideoScan/FamilySearchPullSheet.swift:405:18
  unused declaration     var.instance                 isDark                                             VideoScan/FamilyTreeCanvasControls.swift:74:9
  assign-only property   var.instance                 person                                             VideoScan/FamilyTreeCards.swift:361:13
  assign-only property   var.instance                 profileID                                          VideoScan/FamilyTreeCards.swift:362:13
  assign-only property   var.instance                 cover                                              VideoScan/FamilyTreeCards.swift:363:13
  assign-only property   var.instance                 coverChosenAt                                      VideoScan/FamilyTreeCards.swift:364:13
  assign-only property   var.instance                 revision                                           VideoScan/FamilyTreeCards.swift:365:13
  assign-only property   var.instance                 graph                                              VideoScan/FamilyTreeLaunchBundle.swift:22:9
  assign-only property   var.instance                 ownerFamilySearchID                                VideoScan/FamilyTreeLaunchBundle.swift:28:9
  assign-only property   var.instance                 rootID                                             VideoScan/FamilyTreeLayout.swift:77:13
  unused parameter       var.parameter                id                                                 VideoScan/FamilyTreeLiveModel.swift:1332:30
  unused declaration     function.method.instance     sharedAncestors(of:and:limit:)                     VideoScan/FamilyTreeLiveModel.swift:1850:10
  unused declaration     function.method.static       year(in:)                                          VideoScan/FamilyTreeLiveModel.swift:2256:29
  unused declaration     var.static                   productionOriginalsDirectory                       VideoScan/FamilyTreeLiveModel.swift:494:28
  assign-only property   var.instance                 cyberBrainPersonID                                 VideoScan/FamilyTreeNotes.swift:40:9
  unused declaration     function.method.instance     readOnlyField(_:_:)                                VideoScan/FamilyTreeView.swift:1796:18
  unused declaration     var.instance                 showCopies                                         VideoScan/FileJourneySheet.swift:17:24
  unused declaration     function.method.static       write(records:root:date:)                          VideoScan/Formatting.swift:105:17
  assign-only property   var.instance                 bufferCapacity                                     VideoScan/FramePrefetcher.swift:17:17
  unused declaration     function.method.static       tree(from:depth:in:photo:)                         VideoScan/HallieAttachment.swift:227:17
  assign-only property   var.instance                 cropOffsetX                                        VideoScan/HallieAttachment.swift:78:9
  assign-only property   var.instance                 cropOffsetY                                        VideoScan/HallieAttachment.swift:79:9
  assign-only property   var.instance                 cropScale                                          VideoScan/HallieAttachment.swift:80:9
  unused declaration     function.method.static       recordCode(_:)                                     VideoScan/HallieBiographyCard.swift:504:17
  assign-only property   var.instance                 from                                               VideoScan/HallieBirthplaceTrail.swift:343:13
C assign-only property   var.instance                 id                                                 VideoScan/HallieConversationLog.swift:31:13
C assign-only property   var.instance                 title                                              VideoScan/HallieConversationLog.swift:32:13
C assign-only property   var.instance                 attribution                                        VideoScan/HallieConversationLog.swift:33:13
C assign-only property   var.instance                 locator                                            VideoScan/HallieConversationLog.swift:35:13
C assign-only property   var.instance                 version                                            VideoScan/HallieConversationLog.swift:38:9
  unused declaration     module                       VideoScanCore                                      VideoScan/HallieGalleryAnswer.swift:10:1
  unused parameter       var.parameter                kind                                               VideoScan/HallieGeneralAnswerBoundary.swift:71:9
  unused declaration     function.method.static       typedFamilyName(_:isKnownPerson:)                  VideoScan/HallieGeneralKnowledgeLane.swift:323:17
  unused declaration     function.method.static       decide(_:isKnownPerson:)                           VideoScan/HallieGeneralKnowledgeLane.swift:86:17
  assign-only property   var.instance                 modified                                           VideoScan/HallieKindWords.swift:150:13
  assign-only property   var.instance                 size                                               VideoScan/HallieKindWords.swift:151:13
  unused declaration     var.instance                 isPeopleTab                                        VideoScan/HallieKinshipApposition.swift:185:13
  unused parameter       var.parameter                q                                                  VideoScan/HallieKinshipApposition.swift:484:11
  assign-only property   var.instance                 isKnownPerson                                      VideoScan/HallieModeClassifier.swift:30:13
  unused parameter       var.parameter                memory                                             VideoScan/HallieModeGate.swift:50:9
  unused declaration     function.method.static       matchCost(_:against:)                              VideoScan/HallieNameSuggestion.swift:109:17
  unused declaration     function.method.instance     resetForTesting()                                  VideoScan/HallieNeuralSpeech.swift:132:10
C assign-only property   var.instance                 id                                                 VideoScan/HallieNeuralSpeech.swift:142:9
C assign-only property   var.instance                 outputDirectory                                    VideoScan/HallieNeuralSpeech.swift:143:9
C assign-only property   var.instance                 voiceName                                          VideoScan/HallieNeuralSpeech.swift:144:9
C assign-only property   var.instance                 speed                                              VideoScan/HallieNeuralSpeech.swift:145:9
C assign-only property   var.instance                 text                                               VideoScan/HallieNeuralSpeech.swift:146:9
  unused declaration     module                       VideoScanCore                                      VideoScan/HallieOfferAcceptance.swift:27:1
  unused declaration     module                       VideoScanCore                                      VideoScan/HalliePhotoCaption.swift:17:1
  unused declaration     function.method.static       isContentObject(_:in:)                             VideoScan/HalliePlaceFacet.swift:228:17
  unused declaration     function.method.static       hasLocationShape(_:in:)                            VideoScan/HalliePlaceFacet.swift:235:17
  assign-only property   var.instance                 consumed                                           VideoScan/HalliePlaceFacet.swift:43:13
  assign-only property   var.instance                 fromQuestion                                       VideoScan/HalliePlaceFacet.swift:45:13
C assign-only property   var.instance                 name                                               VideoScan/HalliePronunciationDrillList.swift:315:13
C unused declaration     var.instance                 version                                            VideoScan/HalliePronunciationDrillList.swift:376:9
C assign-only property   var.instance                 hint                                               VideoScan/HalliePronunciationDrillList.swift:502:13
C assign-only property   var.instance                 carriers                                           VideoScan/HalliePronunciationDrillList.swift:503:13
C assign-only property   var.instance                 version                                            VideoScan/HalliePronunciationDrillList.swift:506:9
C assign-only property   var.instance                 generatedAt                                        VideoScan/HalliePronunciationDrillList.swift:507:9
  unused declaration     function.method.static       hintNeedsSpellingReply(_:session:)                 VideoScan/HalliePronunciationDrillMode.swift:299:17
  unused declaration     function.method.static       hintNeedsSpellingReply(_:)                         VideoScan/HalliePronunciationHint.swift:247:17
  assign-only property   var.instance                 path                                               VideoScan/HalliePronunciationLexicon.swift:685:13
  assign-only property   var.instance                 modified                                           VideoScan/HalliePronunciationLexicon.swift:686:13
  assign-only property   var.instance                 size                                               VideoScan/HalliePronunciationLexicon.swift:687:13
  unused parameter       var.parameter                number                                             VideoScan/HalliePronunciationPicker.swift:294:49
  assign-only property   var.instance                 playable                                           VideoScan/HallieRemoteClient.swift:30:13
  assign-only property   var.instance                 native                                             VideoScan/HallieRemoteClient.swift:31:13
  assign-only property   var.instance                 attachmentCount                                    VideoScan/HallieRemoteClient.swift:58:9
  assign-only property   var.instance                 listening                                          VideoScan/HallieRemoteClient.swift:59:9
  unused parameter       var.parameter                options                                            VideoScan/HallieShellCLI+Drill.swift:178:9
  unused declaration     module                       VideoScanCore                                      VideoScan/HallieShellCLI+Render.swift:7:1
  unused parameter       var.parameter                question                                           VideoScan/HallieShellCLI.swift:1450:9
  unused parameter       var.parameter                state                                              VideoScan/HallieShellCLI.swift:1452:9
  assign-only property   var.instance                 executeTurn                                        VideoScan/HallieShellCLI.swift:151:13
  assign-only property   var.instance                 performMediaAction                                 VideoScan/HallieShellCLI.swift:166:13
  unused declaration     var.instance                 effectiveName                                      VideoScan/HallieSpeakerBinding.swift:138:13
  unused declaration     function.method.static       nextQuestion(_:)                                   VideoScan/HallieTellingMode.swift:345:17
  assign-only property   var.instance                 lastRelation                                       VideoScan/HallieTurnExecutor+Conversation.swift:138:17
  assign-only property   var.instance                 chain                                              VideoScan/HallieTurnExecutor+Conversation.swift:158:17
  assign-only property   var.instance                 outcome                                            VideoScan/HallieTurnExecutor+Conversation.swift:198:17
  unused parameter       var.parameter                intent                                             VideoScan/HallieTurnExecutor+Conversation.swift:337:42
  assign-only property   var.instance                 lastYears                                          VideoScan/HallieTurnExecutor+Conversation.swift:50:26
  assign-only property   var.instance                 recordID                                           VideoScan/HallieTurnExecutor+Conversation.swift:594:13
  unused parameter       var.parameter                graph                                              VideoScan/HallieTurnExecutor+FamilyKnowledge.swift:192:35
  unused parameter       var.parameter                relation                                           VideoScan/HallieTurnExecutor+FamilyKnowledge.swift:71:34
  unused parameter       var.parameter                graph                                              VideoScan/HallieTurnExecutor+FamilyKnowledge.swift:72:34
  unused parameter       var.parameter                request                                            VideoScan/HallieTurnExecutor+Record.swift:48:9
  unused parameter       var.parameter                index                                              VideoScan/HallieTurnExecutor+Service.swift:138:49
  unused declaration     function.method.static       execute(_:context:dependencies:)                   VideoScan/HallieTurnExecutor.swift:1077:17
  unused declaration     function.method.static       generalVerdict(_:isKnownPerson:)                   VideoScan/HallieTurnInterpretation.swift:189:17
  unused declaration     var.static                   doubleCollapseTargets                              VideoScan/HallieTypoNormalizer+Lexicon.swift:166:16
  unused declaration     var.static                   possessionFollowers                                VideoScan/HallieTypoNormalizer.swift:307:16
  assign-only property   var.instance                 original                                           VideoScan/HallieTypoNormalizer.swift:61:13
  assign-only property   var.instance                 bridge                                             VideoScan/HallieWebAccess.swift:23:17
  unused parameter       var.parameter                peer                                               VideoScan/HallieWebBridge.swift:122:47
  assign-only property   var.instance                 lastCitations                                      VideoScan/HallieWebBridge.swift:51:13
  unused declaration     module                       VideoScanCore                                      VideoScan/HallieWebPoster.swift:9:1
  unused declaration     module                       VideoScanCore                                      VideoScan/HallieWebProxy.swift:19:1
C unused declaration     var.instance                 friendlyReason                                     VideoScan/HoldoutClearStore.swift:103:9
C assign-only property   var.instance                 savedAt                                            VideoScan/HoldoutClearStore.swift:114:9
  assign-only property   var.instance                 queueKey                                           VideoScan/HoldoutClearStore.swift:175:13
  assign-only property   var.instance                 reviewId                                           VideoScan/HoldoutClearStore.swift:176:13
  unused declaration     function.method.instance     clearAll()                                         VideoScan/HoldoutClearStore.swift:289:10
C unused declaration     var.instance                 friendlyLabel                                      VideoScan/HoldoutClearStore.swift:72:9
  assign-only property   var.instance                 queueKey                                           VideoScan/HoldoutReviewBadgePopover.swift:84:13
  assign-only property   var.instance                 clears                                             VideoScan/HoldoutReviewBadgePopover.swift:85:13
  unused declaration     function.method.instance     metric(_:value:)                                   VideoScan/IdentifyFamilyView.swift:400:18
C assign-only property   var.instance                 savedAt                                            VideoScan/IgnoredContentStore.swift:112:9
  unused declaration     function.method.instance     clear()                                            VideoScan/IgnoredContentStore.swift:297:10
  unused parameter       var.parameter                date                                               VideoScan/InspectorDateView.swift:132:33
  unused declaration     function.method.instance     inspectorThumbnail(for:)                           VideoScan/InspectorPanel.swift:791:18
  assign-only property   var.instance                 row                                                VideoScan/KinshipValidation.swift:293:13
  unused declaration     var.instance                 name                                               VideoScan/LogSink.swift:29:9
  unused declaration     function.method.instance     start(append:)                                     VideoScan/LogSink.swift:39:10
  unused declaration     function.method.instance     close()                                            VideoScan/LogSink.swift:60:10
  unused declaration     var.static                   familyTreeBucket                                   VideoScan/MasterArchive.swift:165:16
  unused parameter       var.parameter                hasPair                                            VideoScan/MediaAnalyzer.swift:207:29
  assign-only property   var.instance                 classified                                         VideoScan/MediaAnalyzer.swift:284:13
  unused declaration     var.static                   KB                                                 VideoScan/MediaBytes.swift:34:16
  unused declaration     var.static                   MB                                                 VideoScan/MediaBytes.swift:35:16
  unused declaration     var.static                   TB                                                 VideoScan/MediaBytes.swift:37:16
  unused declaration     var.static                   PB                                                 VideoScan/MediaBytes.swift:38:16
  unused declaration     var.instance                 colorScheme                                        VideoScan/MediaDistributionSheet.swift:41:45
  assign-only property   var.instance                 index                                              VideoScan/MediaPairComparator.swift:126:13
  unused declaration     var.instance                 all                                                VideoScan/MediaPersonLinks.swift:72:9
  unused declaration     var.instance                 isLocal                                            VideoScan/MediaStreamResolver.swift:76:9
  unused declaration     function.method.instance     incrementWorkers()                                 VideoScan/MemoryPressure.swift:69:10
  assign-only property   var.instance                 id                                                 VideoScan/MissingAudioFinder.swift:122:13
C unused declaration     var.instance                 color                                              VideoScan/ModelsUI/ArchiveModels+Presentation.swift:47:9
  assign-only property   var.instance                 timestamp                                          VideoScan/ModelsUI/CatalogScanTarget.swift:322:9
C unused declaration     var.instance                 color                                              VideoScan/ModelsUI/MediaClassification+Presentation.swift:12:9
C unused declaration     var.instance                 rowColor                                           VideoScan/ModelsUI/VideoRecord+Presentation.swift:69:9
  assign-only property   var.instance                 isReachable                                        VideoScan/ModelsUI/VolumeViewModels.swift:29:9
  assign-only property   var.instance                 isNetwork                                          VideoScan/ModelsUI/VolumeViewModels.swift:30:9
  assign-only property   var.instance                 catalogStatusText                                  VideoScan/ModelsUI/VolumeViewModels.swift:31:9
  assign-only property   var.instance                 frameLayout                                        VideoScan/MxfHeaderParser.swift:32:13
  unused declaration     function.constructor         init(embedder:params:pauseGate:onProgress:)        VideoScan/NativeRecipeScorer.swift:124:5
  unused parameter       var.parameter                samplingFPS                                        VideoScan/NativeRecipeScorer.swift:532:47
  assign-only property   var.instance                 eraCentroids                                       VideoScan/NativeRecipeScorer.swift:91:17
  unused declaration     var.instance                 displayName                                        VideoScan/OllamaFailoverTranslator.swift:84:9
  unused declaration     var.instance                 displayName                                        VideoScan/OllamaQueryTranslator.swift:18:9
  unused declaration     function.method.instance     translate(_:)                                      VideoScan/OllamaQueryTranslator.swift:19:10
  unused declaration     var.instance                 hasFullName                                        VideoScan/POINameForms.swift:199:9
  unused declaration     enumelement                  skippedAlreadyRun                                  VideoScan/POIStorage.swift:305:14
C assign-only property   var.instance                 startedAt                                          VideoScan/POIStorage.swift:423:13
C assign-only property   var.instance                 backupVerified                                     VideoScan/POIStorage.swift:430:13
  assign-only property   var.instance                 distances                                          VideoScan/PerceptualHash.swift:68:9
C assign-only property   var.instance                 hitCount                                           VideoScan/PersonEvaluationCLI.swift:401:13
C assign-only property   var.instance                 video                                              VideoScan/PersonEvaluationCLI.swift:411:13
C assign-only property   var.instance                 bestDist                                           VideoScan/PersonEvaluationCLI.swift:417:13
C assign-only property   var.instance                 start                                              VideoScan/PersonEvaluationCLI.swift:61:13
C assign-only property   var.instance                 end                                                VideoScan/PersonEvaluationCLI.swift:62:13
C assign-only property   var.instance                 bestDistance                                       VideoScan/PersonEvaluationCLI.swift:63:13
C assign-only property   var.instance                 averageDistance                                    VideoScan/PersonEvaluationCLI.swift:64:13
C assign-only property   var.instance                 schemaVersion                                      VideoScan/PersonEvaluationCLI.swift:78:13
C assign-only property   var.instance                 person                                             VideoScan/PersonEvaluationCLI.swift:79:13
C assign-only property   var.instance                 engine                                             VideoScan/PersonEvaluationCLI.swift:80:13
C assign-only property   var.instance                 video                                              VideoScan/PersonEvaluationCLI.swift:81:13
C assign-only property   var.instance                 facesDetected                                      VideoScan/PersonEvaluationCLI.swift:82:13
C assign-only property   var.instance                 hits                                               VideoScan/PersonEvaluationCLI.swift:83:13
C assign-only property   var.instance                 bestDistance                                       VideoScan/PersonEvaluationCLI.swift:84:13
C assign-only property   var.instance                 segments                                           VideoScan/PersonEvaluationCLI.swift:85:13
C assign-only property   var.instance                 elapsedSeconds                                     VideoScan/PersonEvaluationCLI.swift:86:13
C assign-only property   var.instance                 peakRSSMB                                          VideoScan/PersonEvaluationCLI.swift:87:13
C assign-only property   var.instance                 aggregation                                        VideoScan/PersonEvaluationCLI.swift:89:13
C assign-only property   var.instance                 presence                                           VideoScan/PersonEvaluationCLI.swift:90:13
  assign-only property   var.instance                 cachedAt                                           VideoScan/PersonFinderCache.swift:347:13
  unused declaration     function.free                pfCatalogSkipSet()                                 VideoScan/PersonFinderCatalogFilter.swift:34:6
  unused declaration     var.instance                 totalDropsAcrossCategories                         VideoScan/PersonFinderCatalogFilter.swift:73:9
  assign-only property   var.instance                 vProfile                                           VideoScan/PersonFinderCompilation.swift:159:9
  assign-only property   var.instance                 width                                              VideoScan/PersonFinderCompilation.swift:161:9
  assign-only property   var.instance                 sar                                                VideoScan/PersonFinderCompilation.swift:163:9
  assign-only property   var.instance                 colorSpace                                         VideoScan/PersonFinderCompilation.swift:165:9
  assign-only property   var.instance                 colorRange                                         VideoScan/PersonFinderCompilation.swift:166:9
  assign-only property   var.instance                 aLayout                                            VideoScan/PersonFinderCompilation.swift:171:9
  unused parameter       var.parameter                scanSettings                                       VideoScan/PersonFinderCompilation.swift:623:9
  unused parameter       var.parameter                total                                              VideoScan/PersonFinderDetection.swift:486:17
  unused parameter       var.parameter                index                                              VideoScan/PersonFinderDetection.swift:486:5
  assign-only property   var.instance                 filename                                           VideoScan/PersonFinderInspectorTypes.swift:16:9
  assign-only property   var.instance                 duration                                           VideoScan/PersonFinderInspectorTypes.swift:18:9
  unused declaration     var.instance                 referenceFeaturePrints                             VideoScan/PersonFinderModel.swift:426:9
  assign-only property   var.instance                 timestamp                                          VideoScan/PersonFinderModel.swift:833:13
  unused declaration     struct                       ReferenceFaceCard                                  VideoScan/PersonFinderSubviews.swift:28:8
C unused declaration     var.instance                 hasCoverCrop                                       VideoScan/PersonFinderTypes.swift:1212:9
  assign-only property   var.instance                 label                                              VideoScan/PersonFinderTypes.swift:1418:9
  unused parameter       var.parameter                oldName                                            VideoScan/PersonFinderTypes.swift:884:28
  unused declaration     function.method.instance     browseForOutput()                                  VideoScan/PersonFinderView+Helpers.swift:86:10
  unused declaration     var.instance                 hasAnyResults                                      VideoScan/PersonFinderView.swift:86:9
  unused declaration     function.method.instance     peoplePhoto(for:among:kinshipCenter:)              VideoScan/PersonPhotoResolver.swift:449:10
  assign-only property   var.instance                 chosenAt                                           VideoScan/PersonPhotoResolver.swift:61:9
  assign-only property   var.instance                 mtime                                              VideoScan/PreviewFrameRoute.swift:39:13
  assign-only property   var.instance                 fileSize                                           VideoScan/PreviewFrameRoute.swift:40:13
  assign-only property   var.instance                 isReachable                                        VideoScan/PreviewSweepService.swift:125:13
  assign-only property   var.instance                 manifestURL                                        VideoScan/PromoteToArchiveJob+Steps.swift:16:13
  assign-only property   var.instance                 journalURL                                         VideoScan/PromoteToArchiveJob+Steps.swift:17:13
  assign-only property   var.instance                 recordID                                           VideoScan/ProvenanceTypes.swift:215:9
  assign-only property   var.instance                 sourceRole                                         VideoScan/ProvenanceTypes.swift:251:9
  assign-only property   var.instance                 volumeRootPath                                     VideoScan/ProvenanceTypes.swift:36:9
  assign-only property   var.instance                 sourceVolumeRootPath                               VideoScan/ProvenanceTypes.swift:77:9
  unused declaration     function.method.instance     refuseToStart(reason:)                             VideoScan/PruneApplyJob.swift:378:10
  unused declaration     var.static                   isEnabled                                          VideoScan/RAMAssetLoader.swift:202:16
  unused declaration     var.static                   maxFileSizeBytes                                   VideoScan/RAMAssetLoader.swift:203:16
  unused declaration     function.method.static       warm(fileURL:)                                     VideoScan/RAMAssetLoader.swift:207:17
  unused declaration     var.instance                 currentRefCount                                    VideoScan/RAMDisk.swift:100:9
  assign-only property   var.instance                 initialJobID                                       VideoScan/RealtimeFaceDetectionWindow.swift:521:9
  assign-only property   var.instance                 initialJobID                                       VideoScan/RealtimeFaceDetectionWindow.swift:73:9
  unused declaration     var.global                   genderAgeLog                                       VideoScan/RecipeGenderAgeGate.swift:41:13
  unused declaration     var.instance                 addedCount                                         VideoScan/ReferencePhotoImporter.swift:26:13
  unused parameter       var.parameter                cancelled                                          VideoScan/ReformatJob.swift:453:25
  assign-only property   var.instance                 recordID                                           VideoScan/RelocateEngine.swift:17:9
  assign-only property   var.instance                 size                                               VideoScan/RelocateReconcile.swift:677:13
  assign-only property   var.instance                 md5                                                VideoScan/RelocateReconcile.swift:678:13
  assign-only property   var.instance                 destinationRootPath                                VideoScan/RelocateSummary.swift:36:9
  unused declaration     var.instance                 showDegraded                                       VideoScan/RelocateSummarySheet.swift:41:24
  unused declaration     var.instance                 showSalvageFailed                                  VideoScan/RelocateSummarySheet.swift:45:24
C unused declaration     var.static                   schemaVersion                                      VideoScan/ResearchPerson.swift:375:16
C unused declaration     var.instance                 schemaVersion                                      VideoScan/ResearchPerson.swift:377:9
C assign-only property   var.instance                 sex                                                VideoScan/ResearchPerson.swift:41:9
  unused declaration     var.instance                 openWindow                                         VideoScan/RipAllFramesSheet.swift:27:36
  unused declaration     var.instance                 summaryText                                        VideoScan/ScanJobRow+Summary.swift:34:17
  unused declaration     var.static                   ciContext                                          VideoScan/SeekingFrameProvider.swift:29:24
  unused declaration     var.static                   candidateDisclaimer                                VideoScan/SignatureVerification.swift:1007:16
  assign-only property   var.instance                 verifiedAt                                         VideoScan/SignatureVerification.swift:92:9
  unused parameter       var.parameter                cancelled                                          VideoScan/TranscodeJob.swift:782:25
  unused declaration     var.instance                 codecTag                                           VideoScan/TranscodePreset.swift:29:9
  unused declaration     var.instance                 humanLabel                                         VideoScan/TranscodePreset.swift:73:9
  unused declaration     var.instance                 openWindow                                         VideoScan/TranscodeSheet.swift:10:44
  assign-only property   var.instance                 subjects                                           VideoScan/TreeIdentityCenter.swift:125:13
  assign-only property   var.instance                 ownerName                                          VideoScan/TreeIdentityCenter.swift:126:13
  assign-only property   var.instance                 ownerFamilySearchID                                VideoScan/TreeIdentityCenter.swift:127:13
  assign-only property   var.instance                 generation                                         VideoScan/TreeIdentityCenter.swift:131:13
  assign-only property   var.instance                 signature                                          VideoScan/TreeIdentityCenter.swift:132:13
  assign-only property   var.instance                 refreshKey                                         VideoScan/TreeIdentityCenter.swift:293:13
  assign-only property   var.instance                 pinsRevision                                       VideoScan/TreeIdentityCenter.swift:294:13
  assign-only property   var.instance                 derivationRunCount                                 VideoScan/TreeIdentityCenter.swift:295:13
  assign-only property   var.instance                 ownerName                                          VideoScan/TreeIdentityDeriver.swift:202:9
  unused parameter       var.parameter                other                                              VideoScan/TreeIdentityDeriver.swift:514:74
  unused declaration     var.instance                 openWindow                                         VideoScan/TriageView.swift:91:44
  unused declaration     var.instance                 openWindow                                         VideoScan/TrimSheet.swift:107:44
  unused declaration     var.instance                 isEmpty                                            VideoScan/UnifiedReviewSession.swift:281:9
C assign-only property   var.instance                 score                                              VideoScan/ValidationLabel.swift:37:9
  assign-only property   var.instance                 recordID                                           VideoScan/VerifyArchiveCopiesJob.swift:155:13
  assign-only property   var.instance                 rootPath                                           VideoScan/VerifyArchiveCopiesJob.swift:176:9
C assign-only property   var.instance                 index                                              VideoScan/VerifyAudioProbe.swift:401:13
C assign-only property   var.instance                 bit_rate                                           VideoScan/VerifyAudioProbe.swift:407:13
  unused declaration     var.instance                 openWindow                                         VideoScan/VerifyAudioSheet.swift:79:44
  assign-only property   var.instance                 topMaxHeight                                       VideoScan/VerticalSplitView.swift:45:9
  assign-only property   var.instance                 batchID                                            VideoScan/VideoScanModel+ArchiveAngelBufferHygiene.swift:100:9
  unused declaration     var.instance                 peopleInstalledCount                               VideoScan/VideoScanModel+BundleImportExport.swift:285:13
  unused declaration     function.method.instance     exportCatalogViaPanel()                            VideoScan/VideoScanModel+CatalogImportExport.swift:198:10
  unused declaration     function.method.instance     importCatalogViaPanel()                            VideoScan/VideoScanModel+CatalogImportExport.swift:218:10
  assign-only property   var.instance                 original                                           VideoScan/VideoScanModel+CatalogImportExport.swift:297:13
  unused declaration     var.instance                 coverArtMusicPurgeCandidates                       VideoScan/VideoScanModel+CoverArtMusicPurge.swift:49:9
C assign-only property   var.instance                 savedAt                                            VideoScan/VideoScanModel+DateInference.swift:540:13
C assign-only property   var.instance                 reason                                             VideoScan/VideoScanModel+DateInference.swift:541:13
  unused declaration     function.method.static       refusalNote(_:keeper:)                             VideoScan/VideoScanModel+Duplicates.swift:853:17
  assign-only property   var.instance                 path                                               VideoScan/VideoScanModel+EmbeddedDateBackfill.swift:95:13
  unused declaration     var.instance                 offlineBytes                                       VideoScan/VideoScanModel+JunkDelete.swift:463:13
  unused declaration     function.method.instance     stopLiveDossierReload()                            VideoScan/VideoScanModel+LiveReload.swift:64:10
  unused declaration     function.method.instance     sourceID(ofCopyID:in:version:)                     VideoScan/VideoScanModel+MasterArchive.swift:205:10
  unused declaration     function.method.instance     invalidate()                                       VideoScan/VideoScanModel+MasterArchive.swift:210:10
  assign-only property   var.instance                 rootPath                                           VideoScan/VideoScanModel+MasterArchive.swift:392:13
  unused declaration     var.instance                 line                                               VideoScan/VideoScanModel+PruneApply.swift:173:13
  assign-only property   var.instance                 archiveFilename                                    VideoScan/VideoScanModel+PruneApply.swift:349:13
  assign-only property   var.instance                 filename                                           VideoScan/VideoScanModel+PruneVerification.swift:166:13
  assign-only property   var.instance                 copyID                                             VideoScan/VideoScanModel+PruneVerification.swift:200:13
  assign-only property   var.instance                 archiveID                                          VideoScan/VideoScanModel+PruneVerification.swift:93:13
  unused declaration     enumelement                  destinationUnwritable(_:)                          VideoScan/VideoScanModel+Relocate.swift:85:10
  unused declaration     var.instance                 canceledCount                                      VideoScan/VideoScanModel+RelocateQueue.swift:140:9
  assign-only property   var.instance                 retainedStale                                      VideoScan/VideoScanModel+ScanMerge.swift:253:13
  assign-only property   var.instance                 rootReachable                                      VideoScan/VideoScanModel+ScanMerge.swift:254:13
  unused parameter       var.parameter                protected                                          VideoScan/VideoScanModel+ScanMergeMoveIdentity.swift:363:53
  unused declaration     function.method.instance     deriveMoveAdoptions(root:targetRecords:existingPathsUnderRoot:genuinelyGone:outsideRootCandidateExists:) VideoScan/VideoScanModel+ScanMergeMoveIdentity.swift:478:10
  assign-only property   var.instance                 filename                                           VideoScan/VideoScanModel+TrashSelection.swift:44:17
  unused declaration     var.instance                 unrelatedAudioPurgeCount                           VideoScan/VideoScanModel+UnrelatedAudioPurge.swift:41:9
  unused declaration     var.instance                 unrelatedAudioPurgeCandidates                      VideoScan/VideoScanModel+UnrelatedAudioPurge.swift:53:9
  assign-only property   var.instance                 targetID                                           VideoScan/VideoScanModel+UpdateCatalog.swift:121:9
  assign-only property   var.instance                 preview                                            VideoScan/VideoScanModel+UpdateCatalog.swift:126:9
  unused declaration     function.method.instance     exportVolumeInfo()                                 VideoScan/VideoScanModel+VolumeLifecycle.swift:248:10
  assign-only property   var.instance                 newTargetPath                                      VideoScan/VideoScanModel+VolumeRenameMigration.swift:211:9
  unused parameter       var.parameter                now                                                VideoScan/VideoScanModel+VolumeRoleMigration.swift:53:29
  assign-only property   var.instance                 disposedRecords                                    VideoScan/VideoScanModel+VolumeStatusCache.swift:36:9
  assign-only property   var.instance                 mountObservers                                     VideoScan/VideoScanModel.swift:1239:9
  unused declaration     var.instance                 showCoverArtMusicPurgeSheet                        VideoScan/VideoScanModel.swift:1359:20
  unused declaration     var.instance                 showUnrelatedAudioPurgeSheet                       VideoScan/VideoScanModel.swift:1368:20
  unused declaration     struct                       MasterOnlyCaption                                  VideoScan/ViewerModeViews.swift:63:8
  assign-only property   var.instance                 alreadySafe                                        VideoScan/VolumeCompare.swift:22:9
  assign-only property   var.instance                 totalSeconds                                       VideoScan/VolumeDashboard.swift:133:9
  unused declaration     var.instance                 expanded                                           VideoScan/VolumeProvenanceSheet.swift:221:24
  unused declaration     var.instance                 showAtRisk                                         VideoScan/VolumeProvenanceSheet.swift:89:24
  unused declaration     var.instance                 isCatalogSelected                                  VideoScan/VolumesWindow.swift:169:17
C assign-only property   var.instance                 id                                                 VideoScan/WhisperWorkerTranscriber.swift:56:9
C assign-only property   var.instance                 path                                               VideoScan/WhisperWorkerTranscriber.swift:57:9
C assign-only property   var.instance                 language                                           VideoScan/WhisperWorkerTranscriber.swift:58:9
C unused declaration     var.instance                 isProbeable                                        VideoScanCore/Sources/VideoScanCore/ArchiveMedium.swift:78:16
  unused declaration     function.method.static       lifeDate(for:birth:in:)                            VideoScanCore/Sources/VideoScanCore/ArchivistBiographyPolicy.swift:186:24
  unused parameter       var.parameter                graph                                              VideoScanCore/Sources/VideoScanCore/ArchivistBiographyPolicy.swift:198:12
  unused parameter       var.parameter                graph                                              VideoScanCore/Sources/VideoScanCore/ArchivistBiographyPolicy.swift:278:37
  unused declaration     function.method.static       biography(for:in:)                                 VideoScanCore/Sources/VideoScanCore/ArchivistBiographyPolicy.swift:77:24
  unused declaration     function.method.static       summary(personID:in:)                              VideoScanCore/Sources/VideoScanCore/ArchivistFamilyTreePolicy.swift:42:24
  unused declaration     function.method.static       answer(for:)                                       VideoScanCore/Sources/VideoScanCore/ArchivistFamilyTreePolicy.swift:81:24
  assign-only property   var.instance                 phase                                              VideoScanCore/Sources/VideoScanCore/CleanupEngine.swift:78:16
  assign-only property   var.instance                 passIndex                                          VideoScanCore/Sources/VideoScanCore/CleanupEngine.swift:82:16
  assign-only property   var.instance                 passCount                                          VideoScanCore/Sources/VideoScanCore/CleanupEngine.swift:84:16
  unused declaration     function.method.static       recipe(id:)                                        VideoScanCore/Sources/VideoScanCore/CleanupRecipe.swift:148:24
C assign-only property   var.instance                 computedAt                                         VideoScanCore/Sources/VideoScanCore/ContentFixity.swift:126:16
  assign-only property   var.instance                 generation                                         VideoScanCore/Sources/VideoScanCore/CyberBrainIndex.swift:13:16
  unused parameter       var.parameter                index                                              VideoScanCore/Sources/VideoScanCore/CyberBrainIndex.swift:270:9
C assign-only property   var.instance                 place                                              VideoScanCore/Sources/VideoScanCore/CyberBrainModels.swift:124:16
C assign-only property   var.instance                 precision                                          VideoScanCore/Sources/VideoScanCore/CyberBrainModels.swift:180:16
C assign-only property   var.instance                 qualifier                                          VideoScanCore/Sources/VideoScanCore/CyberBrainModels.swift:181:16
C assign-only property   var.instance                 permittedActions                                   VideoScanCore/Sources/VideoScanCore/CyberBrainModels.swift:300:16
C assign-only property   var.instance                 constraints                                        VideoScanCore/Sources/VideoScanCore/CyberBrainModels.swift:301:16
  unused declaration     function.method.static       ffmpegIsAvailable(environment:fileManager:)        VideoScanCore/Sources/VideoScanCore/FFmpegLocator.swift:84:24
  unused declaration     struct                       FFmpegPreviewRenderer                              VideoScanCore/Sources/VideoScanCore/FFmpegPreviewRenderer.swift:32:15
C assign-only property   var.instance                 size                                               VideoScanCore/Sources/VideoScanCore/FamilyGraphCompiledStore.swift:121:20
C assign-only property   var.instance                 modifiedAt                                         VideoScanCore/Sources/VideoScanCore/FamilyGraphCompiledStore.swift:122:20
C assign-only property   var.instance                 mergeReport                                        VideoScanCore/Sources/VideoScanCore/FamilyGraphCompiledStore.swift:167:20
  unused declaration     function.method.instance     remove(_:)                                         VideoScanCore/Sources/VideoScanCore/FamilyIdentityDecisions.swift:187:26
C assign-only property   var.instance                 decidedAt                                          VideoScanCore/Sources/VideoScanCore/FamilyIdentityDecisions.swift:52:16
  unused declaration     function.method.static       slowNormalized(_:)                                 VideoScanCore/Sources/VideoScanCore/FamilyIdentityText.swift:56:17
  unused declaration     function.method.static       slowTokens(_:)                                     VideoScanCore/Sources/VideoScanCore/FamilyIdentityText.swift:63:17
  unused declaration     function.method.static       newLocalKey(randomness:)                           VideoScanCore/Sources/VideoScanCore/FamilyPersonFolderName.swift:123:24
  unused declaration     enum                         FamilyTreeDuplicates                               VideoScanCore/Sources/VideoScanCore/FamilyTreeDuplicates.swift:35:13
  unused declaration     var.instance                 label                                              VideoScanCore/Sources/VideoScanCore/FamilyTreeResearchLinks.swift:40:13
  unused parameter       var.parameter                graph                                              VideoScanCore/Sources/VideoScanCore/FamilyTreeVerification.swift:156:39
C assign-only property   var.instance                 at                                                 VideoScanCore/Sources/VideoScanCore/FindTagJournal.swift:102:16
C assign-only property   var.instance                 seconds                                            VideoScanCore/Sources/VideoScanCore/FindTagJournal.swift:121:16
C assign-only property   var.instance                 reusedFrom                                         VideoScanCore/Sources/VideoScanCore/FindTagJournal.swift:124:16
C assign-only property   var.instance                 at                                                 VideoScanCore/Sources/VideoScanCore/FindTagJournal.swift:148:16
C assign-only property   var.instance                 currentPath                                        VideoScanCore/Sources/VideoScanCore/FindTagJournal.swift:152:16
C assign-only property   var.instance                 at                                                 VideoScanCore/Sources/VideoScanCore/FindTagJournal.swift:170:16
C assign-only property   var.instance                 status                                             VideoScanCore/Sources/VideoScanCore/FindTagJournal.swift:171:16
C assign-only property   var.instance                 scored                                             VideoScanCore/Sources/VideoScanCore/FindTagJournal.swift:172:16
C assign-only property   var.instance                 errors                                             VideoScanCore/Sources/VideoScanCore/FindTagJournal.swift:173:16
C assign-only property   var.instance                 reused                                             VideoScanCore/Sources/VideoScanCore/FindTagJournal.swift:174:16
C assign-only property   var.instance                 skippedHuman                                       VideoScanCore/Sources/VideoScanCore/FindTagJournal.swift:177:16
  assign-only property   var.instance                 fileURL                                            VideoScanCore/Sources/VideoScanCore/FindTagJournal.swift:252:16
C assign-only property   var.instance                 runId                                              VideoScanCore/Sources/VideoScanCore/FindTagJournal.swift:55:16
C assign-only property   var.instance                 at                                                 VideoScanCore/Sources/VideoScanCore/FindTagJournal.swift:56:16
C assign-only property   var.instance                 engine                                             VideoScanCore/Sources/VideoScanCore/FindTagJournal.swift:62:16
C assign-only property   var.instance                 planned                                            VideoScanCore/Sources/VideoScanCore/FindTagJournal.swift:65:16
  unused declaration     var.static                   leftOnlyPair                                       VideoScanCore/Sources/VideoScanCore/GauntletFixturePlan.swift:47:23
  assign-only property   var.instance                 person                                             VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+CommonAncestors.swift:17:20
  assign-only property   var.instance                 pathA                                              VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+CommonAncestors.swift:22:20
  assign-only property   var.instance                 pathB                                              VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+CommonAncestors.swift:23:20
  unused declaration     var.instance                 kinshipTerm                                        VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+CommonAncestors.swift:26:20
  unused declaration     var.instance                 ancestorCount                                      VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+Descent.swift:106:20
  unused declaration     var.static                   empty                                              VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+Index.swift:33:27
  unused declaration     function.method.static       byNameThenID(_:_:)                                 VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+Index.swift:682:17
  unused declaration     function.method.instance     postings(withPrefix:)                              VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+Index.swift:96:21
  unused declaration     var.static                   knownCountries                                     VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+Lineage.swift:317:23
  assign-only property   var.instance                 pointerMap                                         VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+Merge.swift:97:20
  assign-only property   var.instance                 primaryFamilyID                                    VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+ParentFamily.swift:108:20
  assign-only property   var.instance                 ranks                                              VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+ParentFamily.swift:113:20
  assign-only property   var.instance                 familyID                                           VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+ParentFamily.swift:96:20
  unused declaration     class                        InMemoryPreviewSweepFailureStore                   VideoScanCore/Sources/VideoScanCore/InMemoryPreviewSweepFailureStore.swift:14:20
  assign-only property   var.instance                 stop                                               VideoScanCore/Sources/VideoScanCore/LineageTrail.swift:100:20
  unused declaration     function.method.static       lineLabel(of:)                                     VideoScanCore/Sources/VideoScanCore/LineageTrail.swift:134:24
  unused parameter       var.parameter                report                                             VideoScanCore/Sources/VideoScanCore/LineageTrail.swift:142:29
  unused declaration     var.instance                 birthYear                                          VideoScanCore/Sources/VideoScanCore/LineageTrail.swift:94:20
  assign-only property   var.instance                 line                                               VideoScanCore/Sources/VideoScanCore/LineageTrail.swift:99:20
  unused declaration     var.static                   protection                                         VideoScanCore/Sources/VideoScanCore/MediaLedgerEvent.swift:99:27
C unused declaration     var.static                   currentVersion                                     VideoScanCore/Sources/VideoScanCore/PersonFactOverlay.swift:44:23
C unused declaration     var.instance                 version                                            VideoScanCore/Sources/VideoScanCore/PersonFactOverlay.swift:50:16
C assign-only property   var.instance                 displayName                                        VideoScanCore/Sources/VideoScanCore/PersonFactOverlay.swift:90:20
C assign-only property   var.instance                 appliedAt                                          VideoScanCore/Sources/VideoScanCore/PersonFactOverlay.swift:91:20
C assign-only property   var.instance                 facts                                              VideoScanCore/Sources/VideoScanCore/PersonFactOverlay.swift:92:20
C assign-only property   var.instance                 retiredAt                                          VideoScanCore/Sources/VideoScanCore/PersonFactOverlay.swift:93:20
C assign-only property   var.instance                 reason                                             VideoScanCore/Sources/VideoScanCore/PersonFactOverlay.swift:94:20
  assign-only property   var.instance                 familySearchID                                     VideoScanCore/Sources/VideoScanCore/PersonFactRefresh.swift:229:16
  redundant public       function.free                previewStripFilename(key:index:count:offsetMillis:) VideoScanCore/Sources/VideoScanCore/PreviewCacheFormat.swift:107:13
  redundant public       function.free                previewParseStripFilename(_:)                      VideoScanCore/Sources/VideoScanCore/PreviewCacheFormat.swift:116:13
  redundant public       var.global                   previewMaxStripOffsetMillis                        VideoScanCore/Sources/VideoScanCore/PreviewCacheFormat.swift:37:12
  redundant public       function.free                previewCacheKey(path:mtime:size:)                  VideoScanCore/Sources/VideoScanCore/PreviewCacheFormat.swift:60:13
  redundant public       function.free                previewFileSignature(atPath:)                      VideoScanCore/Sources/VideoScanCore/PreviewCacheFormat.swift:69:13
  redundant public       function.free                previewTierFilename(key:tier:)                     VideoScanCore/Sources/VideoScanCore/PreviewCacheFormat.swift:81:13
  redundant public       function.free                previewParseTierFilename(_:)                       VideoScanCore/Sources/VideoScanCore/PreviewCacheFormat.swift:89:13
C assign-only property   var.instance                 executablePath                                     VideoScanCore/Sources/VideoScanCore/PreviewHelperSupervisor.swift:102:16
C assign-only property   var.instance                 startSeconds                                       VideoScanCore/Sources/VideoScanCore/PreviewHelperSupervisor.swift:103:16
C assign-only property   var.instance                 startMicroseconds                                  VideoScanCore/Sources/VideoScanCore/PreviewHelperSupervisor.swift:104:16
  unused declaration     function.method.static       isRunning(pidfileURL:isAlive:isLockHeld:identityForPID:) VideoScanCore/Sources/VideoScanCore/PreviewHelperSupervisor.swift:166:24
  redundant public       enum                         PreviewHelperSpawnError                            VideoScanCore/Sources/VideoScanCore/PreviewHelperSupervisor.swift:214:13
  assign-only property   var.instance                 searched                                           VideoScanCore/Sources/VideoScanCore/PreviewHelperSupervisor.swift:453:20
  unused declaration     struct                       HelperIdleExitPolicy                               VideoScanCore/Sources/VideoScanCore/PreviewHelperSupervisor.swift:526:15
  redundant public       struct                       PreviewHelperSupervisor                            VideoScanCore/Sources/VideoScanCore/PreviewHelperSupervisor.swift:57:15
  redundant public       function.constructor         init()                                             VideoScanCore/Sources/VideoScanCore/PreviewHelperSupervisor.swift:59:12
  redundant public       function.method.instance     decide(enabled:isRunning:event:)                   VideoScanCore/Sources/VideoScanCore/PreviewHelperSupervisor.swift:82:17
  unused declaration     var.static                   valueFlags                                         VideoScanCore/Sources/VideoScanCore/PreviewSweepCLIOptions.swift:120:24
  unused declaration     function.method.static       isValueFlag(_:)                                    VideoScanCore/Sources/VideoScanCore/PreviewSweepCLIOptions.swift:121:25
  unused declaration     function.method.static       applyValueFlag(_:_:into:)                          VideoScanCore/Sources/VideoScanCore/PreviewSweepCLIOptions.swift:125:25
  unused declaration     var.static                   usage                                              VideoScanCore/Sources/VideoScanCore/PreviewSweepCLIOptions.swift:147:23
  unused declaration     enum                         Mode                                               VideoScanCore/Sources/VideoScanCore/PreviewSweepCLIOptions.swift:14:17
  unused declaration     struct                       CatalogFreshness                                   VideoScanCore/Sources/VideoScanCore/PreviewSweepCLIOptions.swift:182:15
  unused declaration     var.instance                 catalogURL                                         VideoScanCore/Sources/VideoScanCore/PreviewSweepCLIOptions.swift:23:16
  unused declaration     var.instance                 mode                                               VideoScanCore/Sources/VideoScanCore/PreviewSweepCLIOptions.swift:24:16
  unused declaration     var.instance                 dryRun                                             VideoScanCore/Sources/VideoScanCore/PreviewSweepCLIOptions.swift:26:16
  unused declaration     var.instance                 workerCount                                        VideoScanCore/Sources/VideoScanCore/PreviewSweepCLIOptions.swift:28:16
  unused declaration     var.instance                 intervalSeconds                                    VideoScanCore/Sources/VideoScanCore/PreviewSweepCLIOptions.swift:30:16
  assign-only property   var.instance                 cacheDirOverride                                   VideoScanCore/Sources/VideoScanCore/PreviewSweepCLIOptions.swift:34:16
  unused declaration     var.instance                 idleExitSeconds                                    VideoScanCore/Sources/VideoScanCore/PreviewSweepCLIOptions.swift:40:16
  unused declaration     function.constructor         init(catalogURL:mode:dryRun:workerCount:intervalSeconds:cacheDirOverride:idleExitSeconds:) VideoScanCore/Sources/VideoScanCore/PreviewSweepCLIOptions.swift:42:12
  unused declaration     enum                         ParseError                                         VideoScanCore/Sources/VideoScanCore/PreviewSweepCLIOptions.swift:75:17
  unused declaration     function.method.static       parse(_:defaultCatalog:)                           VideoScanCore/Sources/VideoScanCore/PreviewSweepCLIOptions.swift:85:24
  unused declaration     struct                       PreviewSweepCLIRunner                              VideoScanCore/Sources/VideoScanCore/PreviewSweepCLIRunner.swift:21:15
  unused declaration     class                        FinalStatusBox                                     VideoScanCore/Sources/VideoScanCore/PreviewSweepCLIRunner.swift:230:21
  unused declaration     function.method.instance     eligibleCandidates()                               VideoScanCore/Sources/VideoScanCore/PreviewSweepSeams.swift:28:10
  unused declaration     var.instance                 succeeded                                          VideoScanCore/Sources/VideoScanCore/ProcessRunner.swift:133:20
  unused declaration     function.method.static       run(executable:arguments:)                         VideoScanCore/Sources/VideoScanCore/ProcessRunner.swift:140:24
  unused declaration     var.static                   all                                                VideoScanCore/Sources/VideoScanCore/PrunePlan.swift:393:27
  unused declaration     function.method.static       describe(_:)                                       VideoScanCore/Sources/VideoScanCore/PrunePlan.swift:432:24
  assign-only property   var.instance                 fixityVerified                                     VideoScanCore/Sources/VideoScanCore/PrunePlan.swift:465:20
  assign-only property   var.instance                 familyCount                                        VideoScanCore/Sources/VideoScanCore/PrunePlan.swift:846:20
  assign-only property   var.instance                 trashBytes                                         VideoScanCore/Sources/VideoScanCore/PrunePlan.swift:851:16
  unused declaration     var.instance                 notCoveredFamilies                                 VideoScanCore/Sources/VideoScanCore/PrunePlan.swift:863:16
  unused declaration     function.method.static       birthYears(_:in:)                                  VideoScanCore/Sources/VideoScanCore/TreeStatistics.swift:168:24
  redundant public       struct                       AnalyzeValueWeights                                VideoScanCore/Sources/VideoScanCore/UnplayableLegacyCodecs.swift:101:15
  redundant public       var.static                   longDuration                                       VideoScanCore/Sources/VideoScanCore/UnplayableLegacyCodecs.swift:103:23
  redundant public       var.static                   hasAudio                                           VideoScanCore/Sources/VideoScanCore/UnplayableLegacyCodecs.swift:105:23
  redundant public       var.static                   legacyCodec                                        VideoScanCore/Sources/VideoScanCore/UnplayableLegacyCodecs.swift:107:23
  redundant public       var.static                   quickTimeContainer                                 VideoScanCore/Sources/VideoScanCore/UnplayableLegacyCodecs.swift:109:23
  redundant public       var.static                   preDigitalEraMTime                                 VideoScanCore/Sources/VideoScanCore/UnplayableLegacyCodecs.swift:112:23
C unused declaration     var.instance                 dateCreatedSortKey                                 VideoScanCore/Sources/VideoScanCore/VideoRecord+Derived.swift:186:16
C unused declaration     var.instance                 dateModifiedSortKey                                VideoScanCore/Sources/VideoScanCore/VideoRecord+Derived.swift:189:16
C unused declaration     var.instance                 analyzeValueScore                                  VideoScanCore/Sources/VideoScanCore/VideoRecord+Derived.swift:93:16
C unused declaration     var.instance                 next                                               VideoScanCore/Sources/VideoScanCore/VolumeStatusEnums.swift:42:16
  unused declaration     function.method.static       assess(birthYear:deathYear:medium:)                VideoScanCore/Sources/VideoScanCore/WorldKnowledge.swift:188:28
  unused declaration     var.static                   firstPersonInPhotograph                            VideoScanCore/Sources/VideoScanCore/WorldKnowledge.swift:246:27
  unused declaration     var.static                   year                                               VideoScanCore/Sources/VideoScanCore/WorldKnowledge.swift:249:27
  unused declaration     function.method.static       canHavePhotograph(birthYear:deathYear:)            VideoScanCore/Sources/VideoScanCore/WorldKnowledge.swift:252:28
  unused declaration     function.method.static       canHavePhotograph(person:)                         VideoScanCore/Sources/VideoScanCore/WorldKnowledge.swift:256:28
  assign-only property   var.instance                 source                                             VideoScanCore/Sources/VideoScanCore/WorldKnowledge.swift:55:16
C assign-only property   var.instance                 index                                              VideoScanTests/ArchiveAngelBenchmarkTests.swift:45:13
C assign-only property   var.instance                 path                                               VideoScanTests/ArchiveAngelBenchmarkTests.swift:46:13
C assign-only property   var.instance                 copySeconds                                        VideoScanTests/ArchiveAngelBenchmarkTests.swift:49:13
C assign-only property   var.instance                 prepareSeconds                                     VideoScanTests/ArchiveAngelBenchmarkTests.swift:50:13
C assign-only property   var.instance                 endToEndSeconds                                    VideoScanTests/ArchiveAngelBenchmarkTests.swift:51:13
C assign-only property   var.instance                 testHostPeakRSSBytes                               VideoScanTests/ArchiveAngelBenchmarkTests.swift:54:13
C assign-only property   var.instance                 plan                                               VideoScanTests/ArchiveAngelBenchmarkTests.swift:55:13
C assign-only property   var.instance                 startedAt                                          VideoScanTests/ArchiveAngelTestbed.swift:100:13
  unused declaration     module                       VideoScanCore                                      VideoScanTests/ArchiveDateEntryTests.swift:4:1
  unused declaration     function.method.instance     person(_:)                                         VideoScanTests/ArchivistBirthplaceTests.swift:61:18
  unused declaration     var.instance                 name                                               VideoScanTests/BackupAttestationJournalTests.swift:48:9
  unused declaration     function.method.instance     start(append:)                                     VideoScanTests/BackupAttestationJournalTests.swift:58:10
  unused declaration     function.method.instance     close()                                            VideoScanTests/BackupAttestationJournalTests.swift:60:10
  unused declaration     function.method.static       generateAudioOnly(into:channelCase:duration:)      VideoScanTests/BalanceAudioTestSupport.swift:175:17
  unused declaration     function.method.static       queryBudgetMs(_:corpusSize:)                       VideoScanTests/CatalogSearchBenchmarkTests.swift:115:17
  assign-only property   var.instance                 sizeBytes                                          VideoScanTests/CleanupTestSupport.swift:195:13
  assign-only property   var.instance                 modificationDate                                   VideoScanTests/CleanupTestSupport.swift:196:13
  unused declaration     var.static                   maxCombinesPerTest                                 VideoScanTests/CombinePipelineIntegrationTests.swift:47:16
  unused parameter       var.parameter                name                                               VideoScanTests/ConfirmVerbTests.swift:408:28
  assign-only property   var.instance                 keeper                                             VideoScanTests/DeleteDuplicatesCodex1593Tests.swift:452:13
  assign-only property   var.instance                 sibling                                            VideoScanTests/DeleteDuplicatesCodex1606Tests.swift:159:9
  unused declaration     function.method.instance     opens(_:)                                          VideoScanTests/DeleteDuplicatesCodex1619Tests.swift:110:10
  unused declaration     class                        QAProbe                                            VideoScanTests/DeleteDuplicatesOfferShadowTests.swift:40:21
  unused declaration     function.free                qaQuarantineFolders(_:)                            VideoScanTests/DeleteDuplicatesOfferShadowTests.swift:53:14
  unused declaration     var.instance                 lastLabelPath                                      VideoScanTests/DeleteDuplicatesTierAndSpeedTests.swift:87:17
  unused declaration     var.instance                 quarantinedNames                                   VideoScanTests/DeleteDuplicatesTierAndSpeedTests.swift:93:9
C assign-only property   var.instance                 description                                        VideoScanTests/ExternalMediaRegressionTests.swift:187:9
  unused declaration     function.method.instance     count(_:)                                          VideoScanTests/FamilyTreeRecompileButtonTests.swift:39:14
  assign-only property   var.instance                 message                                            VideoScanTests/FramePrefetcherTests.swift:225:9
  assign-only property   var.instance                 message                                            VideoScanTests/GeneratedMediaPerformanceTests.swift:319:9
  assign-only property   var.instance                 reason                                             VideoScanTests/HallieCompiledGraphWiringTests.swift:193:39
  unused declaration     module                       VideoScanCore                                      VideoScanTests/HallieDeterministicDateTests.swift:40:1
  unused parameter       var.parameter                tag                                                VideoScanTests/HallieKindWordsTests.swift:56:36
  unused declaration     module                       VideoScanCore                                      VideoScanTests/HallieOwnerSuffixTests.swift:4:1
  unused declaration     var.instance                 savedStores                                        VideoScanTests/HalliePronunciationDrillTests.swift:126:13
  assign-only property   var.instance                 motherName                                         VideoScanTests/HallieQueryBench.swift:150:13
  assign-only property   var.instance                 grandfatherName                                    VideoScanTests/HallieQueryBench.swift:151:13
  unused declaration     function.method.instance     callCount(_:)                                      VideoScanTests/HallieQueryBench.swift:75:10
  unused declaration     function.method.instance     totalSeconds(_:)                                   VideoScanTests/HallieQueryBench.swift:76:10
  unused parameter       var.parameter                peer                                               VideoScanTests/HallieRemoteClientTests.swift:44:47
  unused declaration     function.method.instance     start(append:)                                     VideoScanTests/LogSinks+Test.swift:61:10
  unused declaration     var.instance                 name                                               VideoScanTests/MediaLedgerTests.swift:49:9
  unused declaration     function.method.instance     start(append:)                                     VideoScanTests/MediaLedgerTests.swift:54:10
  unused declaration     function.method.instance     close()                                            VideoScanTests/MediaLedgerTests.swift:56:10
  unused declaration     module                       VideoScan                                          VideoScanTests/NotesAuthorshipSensorTests.swift:19:1
  unused parameter       var.parameter                typed                                              VideoScanTests/PeopleTabPrecedenceTests.swift:136:23
  unused declaration     var.static                   photosDir                                          VideoScanTests/PersonFinderLifecycleTests.swift:23:16
  assign-only property   var.instance                 exists                                             VideoScanTests/PreviewDiskCacheTests.swift:52:13
  assign-only property   var.instance                 entryCount                                         VideoScanTests/PreviewDiskCacheTests.swift:53:13
  assign-only property   var.instance                 mtime                                              VideoScanTests/PreviewDiskCacheTests.swift:54:13
  unused parameter       var.parameter                key                                                VideoScanTests/SWRProbeCacheTests.swift:38:18
C assign-only property   var.instance                 benchmark                                          VideoScanTests/SearchBenchSupport.swift:275:9
C assign-only property   var.instance                 metric                                             VideoScanTests/SearchBenchSupport.swift:276:9
C assign-only property   var.instance                 corpusId                                           VideoScanTests/SearchBenchSupport.swift:279:9
C assign-only property   var.instance                 corpusVersion                                      VideoScanTests/SearchBenchSupport.swift:280:9
C assign-only property   var.instance                 corpusSeed                                         VideoScanTests/SearchBenchSupport.swift:281:9
C assign-only property   var.instance                 direction                                          VideoScanTests/SearchBenchSupport.swift:284:9
C assign-only property   var.instance                 correct                                            VideoScanTests/SearchBenchSupport.swift:293:9
  unused declaration     var.static                   donnaSuperstrings                                  VideoScanTests/SearchBenchSupport.swift:63:16
  unused declaration     struct                       TestSetupError                                     VideoScanTests/SeekingFrameProviderTests.swift:134:16
  unused declaration     function.method.instance     skipUnlessTimingIsMeaningful()                     VideoScanTests/StressTests/ArchivistTranscriptRenderSensorTests.swift:133:18
  unused declaration     var.static                   configDir                                          VideoScanTests/StressTests/FixtureMediaStressTests.swift:7:24
  assign-only property   var.instance                 frame                                              VideoScanTests/StressTests/LivePreviewPublishBenchmarkTests.swift:38:13
  assign-only property   var.instance                 matched                                            VideoScanTests/StressTests/LivePreviewPublishBenchmarkTests.swift:39:13
  assign-only property   var.instance                 unmatched                                          VideoScanTests/StressTests/LivePreviewPublishBenchmarkTests.swift:40:13
  unused declaration     function.method.static       cleanupAll()                                       VideoScanTests/TestMediaGenerator.swift:149:17
  unused declaration     function.method.static       outcome(_:named:)                                  VideoScanTests/VerifyArchiveCopiesTests.swift:62:17
  unused parameter       var.parameter                reporting                                          VideoScanTests/VolumeRoleTaxonomyMigrationTests.swift:160:37
```

## Referenced only from tests (in run C, not in run A)

```
unused declaration     function.method.instance     reset()                                            VideoScan/AdaFaceEngine.swift:187:10
unused declaration     function.free                catchObjCException(_:)                             VideoScan/ArcFaceEngine.swift:42:6
unused declaration     var.instance                 recordCount                                        VideoScan/ArchiveAngelAttention.swift:209:9
unused declaration     var.instance                 lastProposedAt                                     VideoScan/ArchiveAngelAttention.swift:54:9
unused declaration     var.instance                 clearable                                          VideoScan/ArchiveAngelBufferHygiene.swift:182:13
unused declaration     var.instance                 clearableBytes                                     VideoScan/ArchiveAngelBufferHygiene.swift:183:13
unused declaration     function.method.instance     clear()                                            VideoScan/ArchiveAngelEvidenceStore.swift:245:10
assign-only property   var.instance                 projections                                        VideoScan/ArchiveAngelJob+Evidence.swift:32:13
assign-only property   var.instance                 cleanupTask                                        VideoScan/ArchiveAngelJob.swift:216:22
assign-only property   var.instance                 skippedAt                                          VideoScan/ArchiveAngelPlan.swift:128:13
unused declaration     function.method.instance     step(_:)                                           VideoScan/ArchiveAngelPlan.swift:151:14
assign-only property   var.instance                 seconds                                            VideoScan/ArchiveAngelPlan.swift:60:13
unused declaration     function.method.instance     stop()                                             VideoScan/ArchiveAngelSweep.swift:204:10
unused declaration     function.method.instance     runAndWait(reason:)                                VideoScan/ArchiveAngelSweep.swift:248:10
unused declaration     var.instance                 isHome                                             VideoScan/ArchiveHomeState.swift:58:9
unused declaration     var.static                   empty                                              VideoScan/ArchiveNudge.swift:42:16
unused declaration     var.instance                 datedCount                                         VideoScan/ArchiveTimelineModel.swift:165:9
assign-only property   var.instance                 checkableBytes                                     VideoScan/ArchivedWhatNextSheet.swift:503:13
assign-only property   var.instance                 source                                             VideoScan/ArchivistAggregateExecutor.swift:15:9
assign-only property   var.instance                 excludedAmbiguousAliases                           VideoScan/ArchivistAggregateExecutor.swift:229:9
assign-only property   var.instance                 excludedUnknownTagSamples                          VideoScan/ArchivistAggregateExecutor.swift:232:9
unused declaration     function.constructor         init(graph:profiles:ownerName:)                    VideoScan/ArchivistGraphExecutor.swift:129:5
assign-only property   var.instance                 relation                                           VideoScan/ArchivistGraphExecutor.swift:392:13
assign-only property   var.instance                 birthDate                                          VideoScan/ArchivistGraphExecutor.swift:407:9
assign-only property   var.instance                 deathDate                                          VideoScan/ArchivistGraphExecutor.swift:408:9
assign-only property   var.instance                 identityBridge                                     VideoScan/ArchivistGraphExecutor.swift:410:9
unused declaration     function.method.static       execute(_:inputs:)                                 VideoScan/ArchivistGraphExecutor.swift:557:17
unused declaration     function.method.static       containsPhrase(_:in:)                              VideoScan/ArchivistKeywordMatching.swift:155:17
unused declaration     var.instance                 visibleIndex                                       VideoScan/ArchivistLivingPortrait.swift:244:13
unused declaration     var.instance                 alpha                                              VideoScan/ArchivistLivingPortrait.swift:246:13
unused declaration     function.method.static       noEvidenceAnswer(for:)                             VideoScan/ArchivistPresenceExecutor.swift:1126:17
assign-only property   var.instance                 evidence                                           VideoScan/ArchivistPresenceExecutor.swift:135:9
assign-only property   var.instance                 isCitationListTruncated                            VideoScan/ArchivistPresenceExecutor.swift:91:9
unused declaration     function.constructor         init(operation:anchorPeople:limit:)                VideoScan/ArchivistQueryAST.swift:186:9
unused declaration     function.constructor         init(people:yearStart:yearEnd:mediaKind:keywords:transcript:) VideoScan/ArchivistQueryAST.swift:215:9
unused declaration     enum                         ArchivistPlayIntentPolicy                          VideoScan/ArchivistQueryPlanner.swift:234:6
unused declaration     enum                         Reply                                              VideoScan/ArchivistQueryPlanner.swift:29:10
unused declaration     function.method.instance     classify(_:)                                       VideoScan/ArchivistQueryPlanner.swift:41:10
unused declaration     function.method.static       consume(_:reply:)                                  VideoScan/ArchivistQueryPlanner.swift:72:17
unused declaration     function.method.static       fold(_:)                                           VideoScan/ArchivistQueryPlanner.swift:82:25
unused declaration     struct                       ArchivistKinshipQuestion                           VideoScan/ArchivistQuestionParser.swift:11:8
unused declaration     enum                         ArchivistQuestionParser                            VideoScan/ArchivistQuestionParser.swift:28:6
unused declaration     enum                         ArchivistGeneralQuestion                           VideoScan/ArchivistQuestionParser.swift:4:6
unused declaration     function.method.static       resolve(_:selectedRecordID:records:recordForID:index:version:deictic:) VideoScan/ArchivistRecordReferenceResolver.swift:120:17
unused declaration     var.instance                 isBuilt                                            VideoScan/ArchivistRecordReferenceResolver.swift:475:9
assign-only property   var.instance                 id                                                 VideoScan/ArchivistRecordReferenceResolver.swift:73:13
assign-only property   var.instance                 subjectID                                          VideoScan/ArchivistTemporalExecutor.swift:275:9
assign-only property   var.instance                 reference                                          VideoScan/ArchivistTemporalExecutor.swift:279:9
assign-only property   var.instance                 evidence                                           VideoScan/ArchivistTemporalExecutor.swift:287:9
unused declaration     function.constructor         init(profile:)                                     VideoScan/ArchivistTemporalExecutor.swift:65:5
unused declaration     function.method.instance     existingAudioCoordinator(for:)                     VideoScan/AssessCopiesJob.swift:143:10
assign-only property   var.instance                 peakDBFS                                           VideoScan/AudioBalanceAnalyzer.swift:88:9
assign-only property   var.instance                 audioChannels                                      VideoScan/AudioBalanceProbe.swift:82:9
unused declaration     struct                       MLXWhisperTranscriber                              VideoScan/AudioTranscriber.swift:240:8
unused declaration     function.method.instance     transcribe(videoPath:)                             VideoScan/AudioTranscriber.swift:80:10
assign-only property   var.instance                 length                                             VideoScan/AvbParser.swift:40:9
unused declaration     function.method.static       expectedOutputStreams(source:)                     VideoScan/BalanceAudioJob.swift:208:17
unused declaration     function.method.instance     queuePosition(of:)                                 VideoScan/CaptionOrchestrator+Queue.swift:104:10
assign-only property   var.instance                 syncedAt                                           VideoScan/CaptionPipelineTypes.swift:121:9
unused declaration     struct                       PythonSubprocessCaptionRunner                      VideoScan/CaptionRunner.swift:773:8
unused declaration     function.method.instance     acquire(waitingUpTo:pollInterval:)                 VideoScan/CatalogLock.swift:148:10
unused declaration     var.instance                 isHeldByUs                                         VideoScan/CatalogLock.swift:93:9
unused declaration     function.method.instance     invalidate()                                       VideoScan/CatalogPerfMemo.swift:66:10
unused declaration     function.free                pfTokenMatches(_:_:)                               VideoScan/CatalogQueries.swift:422:18
unused declaration     function.free                pfRecordMatchesQuery(_:query:)                     VideoScan/CatalogQueries.swift:470:18
unused declaration     function.free                pfRecordsMatchingQuery(_:query:)                   VideoScan/CatalogQueries.swift:477:18
unused declaration     function.free                pfRecordFilenameOrPersonMatch(_:query:)            VideoScan/CatalogQueries.swift:589:18
unused declaration     enum                         TriageDisposition                                  VideoScan/CatalogQueries.swift:624:6
unused declaration     function.free                pfRecordHasVerifiedBackup(_:)                      VideoScan/CatalogQueries.swift:639:18
unused declaration     function.free                pfTriageDisposition(_:autoKeepBelow:autoJunkAbove:requireBackupForJunk:) VideoScan/CatalogQueries.swift:657:18
unused declaration     function.free                pfTriageQueueRecords(from:autoKeepBelow:autoJunkAbove:includeUnbackedJunk:) VideoScan/CatalogQueries.swift:679:18
unused declaration     struct                       TriageBandCounts                                   VideoScan/CatalogQueries.swift:698:8
unused declaration     function.free                pfTriageBandCounts(from:autoKeepBelow:autoJunkAbove:) VideoScan/CatalogQueries.swift:706:18
unused declaration     function.free                pfSetAsideRecords(_:)                              VideoScan/CatalogQueries.swift:786:18
unused declaration     function.free                pfSupersededRecords(_:)                            VideoScan/CatalogQueries.swift:792:18
unused declaration     function.free                pfSearchBadgeBase(_:showRemoved:showSetAside:showSuperseded:kindFacet:) VideoScan/CatalogQueries.swift:852:18
unused declaration     function.method.static       classifyRecord(_:)                                 VideoScan/CatalogScopePolicy.swift:184:29
unused declaration     function.method.static       setAsideReason(for:isVideoLinked:)                 VideoScan/CatalogScopePolicy.swift:193:29
unused declaration     function.method.instance     hasHaystack(for:)                                  VideoScan/CatalogSearchIndex.swift:243:10
unused declaration     function.method.instance     indexedWordCount()                                 VideoScan/CatalogSearchIndex.swift:249:10
unused declaration     function.method.instance     count(records:query:)                              VideoScan/CatalogSearchIndex.swift:288:10
unused declaration     function.method.instance     knownPeople()                                      VideoScan/CatalogSearchIndex.swift:391:10
assign-only property   var.instance                 emphasis                                           VideoScan/CatalogShowingSummary.swift:39:13
assign-only property   var.instance                 action                                             VideoScan/CatalogShowingSummary.swift:40:13
unused declaration     var.instance                 uniqueIsUpperBound                                 VideoScan/CatalogSizeTotals.swift:106:9
unused declaration     function.method.static       compute(records:isArchived:)                       VideoScan/CatalogSizeTotals.swift:214:29
unused declaration     var.instance                 totalDisplay                                       VideoScan/CatalogSizeTotals.swift:233:9
unused declaration     var.instance                 archivedDisplay                                    VideoScan/CatalogSizeTotals.swift:234:9
unused declaration     var.instance                 uniqueDisplay                                      VideoScan/CatalogSizeTotals.swift:235:9
unused declaration     var.instance                 line                                               VideoScan/CatalogSizeTotals.swift:238:9
unused declaration     var.instance                 unhashedTooltip                                    VideoScan/CatalogSizeTotals.swift:244:9
unused declaration     var.instance                 uniqueTooltip                                      VideoScan/CatalogSizeTotals.swift:259:9
assign-only property   var.instance                 directory                                          VideoScan/CatalogSnapshot.swift:34:9
assign-only property   var.instance                 ext                                                VideoScan/CatalogSnapshot.swift:35:9
assign-only property   var.instance                 durationSeconds                                    VideoScan/CatalogSnapshot.swift:40:9
assign-only property   var.instance                 dateCreatedRaw                                     VideoScan/CatalogSnapshot.swift:41:9
assign-only property   var.instance                 dateModifiedRaw                                    VideoScan/CatalogSnapshot.swift:42:9
assign-only property   var.instance                 container                                          VideoScan/CatalogSnapshot.swift:45:9
assign-only property   var.instance                 resolution                                         VideoScan/CatalogSnapshot.swift:48:9
assign-only property   var.instance                 frameRate                                          VideoScan/CatalogSnapshot.swift:49:9
assign-only property   var.instance                 timecode                                           VideoScan/CatalogSnapshot.swift:50:9
assign-only property   var.instance                 avidClipName                                       VideoScan/CatalogSnapshot.swift:56:9
assign-only property   var.instance                 avidMobID                                          VideoScan/CatalogSnapshot.swift:57:9
assign-only property   var.instance                 avidMaterialUUID                                   VideoScan/CatalogSnapshot.swift:58:9
assign-only property   var.instance                 avidTapeName                                       VideoScan/CatalogSnapshot.swift:59:9
assign-only property   var.instance                 pairedWithID                                       VideoScan/CatalogSnapshot.swift:62:9
assign-only property   var.instance                 lifecycleStage                                     VideoScan/CatalogSnapshot.swift:68:9
assign-only property   var.instance                 mediaDisposition                                   VideoScan/CatalogSnapshot.swift:69:9
assign-only property   var.instance                 archiveStage                                       VideoScan/CatalogSnapshot.swift:70:9
assign-only property   var.instance                 detectedPeople                                     VideoScan/CatalogSnapshot.swift:74:9
assign-only property   var.instance                 suspectedPeople                                    VideoScan/CatalogSnapshot.swift:75:9
assign-only property   var.instance                 sceneCaptions                                      VideoScan/CatalogSnapshot.swift:76:9
assign-only property   var.instance                 junkScore                                          VideoScan/CatalogSnapshot.swift:77:9
unused declaration     var.instance                 streamType                                         VideoScan/CatalogSnapshot.swift:80:9
unused declaration     var.instance                 waterfallBalances                                  VideoScan/CatalogStorageTotals.swift:134:9
unused declaration     function.method.static       deepCopySnapshot(records:)                         VideoScan/CatalogStore.swift:1064:17
assign-only property   var.instance                 lastLoadOutcome                                    VideoScan/CatalogStore.swift:279:22
assign-only property   var.instance                 lastGenerationAnomaly                              VideoScan/CatalogStore.swift:339:22
unused declaration     function.method.instance     relinquishLock()                                   VideoScan/CatalogStore.swift:481:10
unused declaration     function.constructor         init(directory:)                                   VideoScan/CatalogStore.swift:500:14
unused declaration     var.instance                 backupLocation                                     VideoScan/CatalogStore.swift:507:9
unused declaration     var.instance                 isSynced                                           VideoScan/CatalogSync.swift:288:9
unused declaration     function.method.instance     writeManifestIfMaster()                            VideoScan/CatalogSync.swift:463:10
unused declaration     function.method.instance     flushManifestRefresh()                             VideoScan/CatalogSync.swift:527:10
unused declaration     function.free                pfCatalogWideTranscriptCandidates(_:)              VideoScan/CatalogWideMetadataCandidates.swift:84:18
unused declaration     var.instance                 isTransient                                        VideoScan/CatalogWriteError.swift:110:9
assign-only property   var.instance                 code                                               VideoScan/CatalogWriteError.swift:129:13
assign-only property   var.instance                 kind                                               VideoScan/CatalogWriteError.swift:130:13
assign-only property   var.instance                 pid                                                VideoScan/CatalogWriteError.swift:132:13
unused declaration     function.method.static       recent(_:catalogURL:)                              VideoScan/CatalogWriteError.swift:209:17
assign-only property   var.instance                 publishedURL                                       VideoScan/CleanupJob.swift:78:22
assign-only property   var.instance                 stderr                                             VideoScan/CombineEngine.swift:11:13
unused declaration     function.method.static       bufferedCopy(from:to:bufferSize:)                  VideoScan/CombineEngine.swift:180:17
assign-only property   var.instance                 videoCodec                                         VideoScan/CopyFamilyAssessor.swift:176:9
unused declaration     function.method.static       buildAudioPools(from:)                             VideoScan/CorrelationScorer.swift:192:17
unused declaration     function.method.static       gatherCandidateAudios(for:vKey:allAudios:byKey:byDir:durationTolerance:timestampTolerance:) VideoScan/CorrelationScorer.swift:206:17
unused declaration     function.method.static       assignCandidates(_:matched:)                       VideoScan/CorrelationScorer.swift:439:17
unused declaration     function.method.static       scoreCandidate(video:audio:)                       VideoScan/Correlator.swift:108:25
unused declaration     function.method.static       filenameCorrelationKey(_:)                         VideoScan/Correlator.swift:158:17
unused declaration     function.method.static       correlatedPairs(from:)                             VideoScan/Correlator.swift:165:17
unused declaration     struct                       Candidate                                          VideoScan/Correlator.swift:183:20
unused declaration     function.method.static       correlate(records:selectedIDs:)                    VideoScan/Correlator.swift:25:17
unused declaration     var.instance                 isEmpty                                            VideoScan/CouplePortrait.swift:149:9
unused declaration     var.instance                 scanDisplayFraction                                VideoScan/DashboardState.swift:126:9
unused declaration     var.instance                 bothOnline                                         VideoScan/DashboardState.swift:588:9
unused declaration     function.free                pfContentEvidenceYear(ocrDateCandidates:audioTranscript:sceneCaptionTexts:) VideoScan/DateTriangulation.swift:196:18
unused declaration     function.method.instance     bucket(for:)                                       VideoScan/DeleteDuplicatesForecast.swift:117:10
unused declaration     var.instance                 runTally                                           VideoScan/DeleteDuplicatesJob.swift:1236:9
unused declaration     var.instance                 inFlightCount                                      VideoScan/DeleteDuplicatesJob.swift:508:9
assign-only property   var.instance                 recordID                                           VideoScan/DeleteDuplicatesPlan.swift:157:13
assign-only property   var.instance                 digest                                             VideoScan/DeleteDuplicatesPlan.swift:161:13
unused declaration     var.instance                 isRemoved                                          VideoScan/DeleteDuplicatesPlan.swift:411:13
assign-only property   var.instance                 settledAt                                          VideoScan/DeleteDuplicatesPlan.swift:432:13
assign-only property   var.instance                 keeperMatchedByStoredFixity                        VideoScan/DeleteDuplicatesPlan.swift:435:13
assign-only property   var.instance                 countedCopies                                      VideoScan/DeleteDuplicatesPlan.swift:457:13
unused declaration     var.instance                 removed                                            VideoScan/DeleteDuplicatesPlan.swift:564:13
unused declaration     var.instance                 discoveryComplete                                  VideoScan/DiscoveryAudit.swift:135:9
unused declaration     function.method.instance     eta(remaining:)                                    VideoScan/DossierDashboardView+Coverage.swift:267:10
unused declaration     function.method.instance     etaDisplayText(remaining:)                         VideoScan/DossierDashboardView+Coverage.swift:283:10
assign-only property   var.instance                 total                                              VideoScan/DossierDashboardView+Coverage.swift:35:9
assign-only property   var.instance                 strongDates                                        VideoScan/DossierDashboardView+Coverage.swift:51:9
unused declaration     var.instance                 jsonlBasename                                      VideoScan/DossierDashboardView+FleetStats.swift:36:9
unused declaration     struct                       FleetStats                                         VideoScan/DossierDashboardView+FleetStats.swift:53:8
assign-only property   var.instance                 ssdMediaErrors                                     VideoScan/DriveHealth.swift:48:9
unused declaration     function.method.instance     canonicalJSON()                                    VideoScan/EvalPresenceRule.swift:80:10
unused declaration     function.constructor         init(members:ownerGedcomID:ownerTokens:)           VideoScan/FamilyAssetIdentityDirectory.swift:60:5
unused declaration     var.static                   sidecarKeys                                        VideoScan/FamilyAssetStore+Documents.swift:107:16
unused declaration     function.method.instance     setExtraSink(_:)                                   VideoScan/FamilyAssetStore+Documents.swift:148:10
unused declaration     function.method.instance     resetMissing()                                     VideoScan/FamilyAssetStore+Documents.swift:153:10
unused declaration     function.method.instance     removeDocument(_:for:)                             VideoScan/FamilyAssetStore+Documents.swift:443:10
assign-only property   var.instance                 sha256                                             VideoScan/FamilyAssetStore+Documents.swift:94:9
assign-only property   var.instance                 compiled                                           VideoScan/FamilyAssetStore.swift:117:13
assign-only property   var.instance                 source                                             VideoScan/FamilyAssetStore.swift:1339:13
unused declaration     var.instance                 loaderRuns                                         VideoScan/FamilyAssetStore.swift:165:9
unused declaration     function.method.instance     loadFamilyGraph(compiledStore:)                    VideoScan/FamilyAssetStore.swift:35:10
unused declaration     function.method.static       profile(name:)                                     VideoScan/FamilyKinship.swift:209:17
assign-only property   var.instance                 pathHash                                           VideoScan/FamilyKinshipInference.swift:124:13
unused declaration     var.instance                 usesTree                                           VideoScan/FamilyKinshipInference.swift:130:13
unused declaration     struct                       Proposal                                           VideoScan/FamilyKinshipInference.swift:155:12
assign-only property   var.instance                 derivationProblems                                 VideoScan/FamilyKinshipInference.swift:206:22
unused declaration     function.method.instance     derivedRelatives(of:)                              VideoScan/FamilyKinshipInference.swift:496:10
unused declaration     function.method.instance     proposals(for:)                                    VideoScan/FamilyKinshipInference.swift:528:10
unused declaration     var.instance                 counters                                           VideoScan/FamilyKinshipInference.swift:548:9
unused declaration     function.method.instance     dropCaches()                                       VideoScan/FamilyKinshipInference.swift:551:10
unused declaration     var.instance                 counters                                           VideoScan/FamilyKinshipInference.swift:860:9
unused declaration     function.method.instance     drop()                                             VideoScan/FamilyKinshipInference.swift:872:10
unused declaration     function.method.instance     warnings(forProfileNamed:)                         VideoScan/FamilyKinshipOverlay+Warnings.swift:43:10
unused declaration     function.method.instance     structuredWarnings(forProfileNamed:)               VideoScan/FamilyKinshipOverlay+Warnings.swift:71:10
unused declaration     function.method.instance     structuredDerivationWarnings(touching:)            VideoScan/FamilyKinshipOverlay+Warnings.swift:76:10
unused declaration     var.instance                 isHalf                                             VideoScan/FamilyKinshipOverlay.swift:219:13
assign-only property   var.instance                 derivationDuration                                 VideoScan/FamilyKinshipOverlay.swift:328:22
unused declaration     var.instance                 edgeCount                                          VideoScan/FamilyKinshipOverlay.swift:383:9
unused declaration     var.instance                 derivedEdgeCount                                   VideoScan/FamilyKinshipOverlay.swift:384:9
unused declaration     function.method.static       entries(directory:log:)                            VideoScan/FamilySearchPersonRefresh.swift:297:29
unused declaration     var.instance                 ids                                                VideoScan/FamilyTreeBookmarks.swift:44:9
unused declaration     var.instance                 mostRecentFirst                                    VideoScan/FamilyTreeBookmarks.swift:57:9
unused declaration     var.instance                 builds                                             VideoScan/FamilyTreeLaunchBundle.swift:104:13
unused declaration     function.method.instance     cached(token:settings:)                            VideoScan/FamilyTreeLaunchBundle.swift:120:14
unused declaration     function.method.instance     invalidate()                                       VideoScan/FamilyTreeLaunchBundle.swift:124:14
unused declaration     function.method.instance     node(forPerson:)                                   VideoScan/FamilyTreeLayout.swift:81:14
unused declaration     function.method.instance     nodes(inGeneration:)                               VideoScan/FamilyTreeLayout.swift:84:14
unused declaration     function.method.instance     loadCyberBrainNow()                                VideoScan/FamilyTreeLiveModel.swift:1595:10
unused declaration     function.method.instance     setPhotoOverride(_:for:)                           VideoScan/FamilyTreeLiveModel.swift:1856:10
unused declaration     function.method.instance     markLoaded(revision:)                              VideoScan/FamilyTreeLiveModel.swift:685:10
unused declaration     function.method.instance     loadNow()                                          VideoScan/FamilyTreeLiveModel.swift:962:10
assign-only property   var.instance                 kind                                               VideoScan/FamilyTreeNotes.swift:33:9
assign-only property   var.instance                 ambiguousPersonIDs                                 VideoScan/FamilyTreeNotes.swift:86:9
unused declaration     function.constructor         init(model:preferences:)                           VideoScan/FamilyTreeView.swift:119:5
unused declaration     var.instance                 usesInjectedModelForTesting                        VideoScan/FamilyTreeView.swift:133:9
unused declaration     function.method.static       fullHash(path:blockSize:)                          VideoScan/FileHasher.swift:211:17
unused declaration     function.method.static       walkDirectory(root:videoExtensions:skipDirs:skipBundleExtensions:skipSmallFiles:probeExtensionless:audioExtensions:scanAudioFiles:scanUnknownExtensions:videoOnlyCatalogScope:audit:onProgress:) VideoScan/FilesystemWalker.swift:330:17
unused declaration     function.method.static       shouldAdmitFile(extension:videoExtensions:audioExtensions:probeExtensionless:scanAudioFiles:scanUnknownExtensions:videoOnlyCatalogScope:) VideoScan/FilesystemWalker.swift:91:17
unused declaration     function.method.static       csvEscape(_:)                                      VideoScan/Formatting.swift:50:17
unused declaration     enum                         CatalogCSVWriter                                   VideoScan/Formatting.swift:58:6
unused declaration     var.instance                 claimIDs                                           VideoScan/HallieAnswerPlan.swift:163:9
unused declaration     var.static                   off                                                VideoScan/HallieAppTurnCoordinator.swift:68:20
assign-only property   var.instance                 capturedReferentID                                 VideoScan/HallieAppTurnCoordinator.swift:86:13
unused declaration     var.instance                 kind                                               VideoScan/HallieAttachment.swift:37:9
assign-only property   var.instance                 role                                               VideoScan/HallieBiographyCard.swift:182:13
assign-only property   var.instance                 looksLikeDuplicate                                 VideoScan/HallieBiographyCard.swift:187:13
unused declaration     var.instance                 evidenceIDs                                        VideoScan/HallieBiographyCard.swift:191:13
unused declaration     var.instance                 text                                               VideoScan/HallieBiographyCard.swift:194:13
unused declaration     function.method.static       marriageClause(_:)                                 VideoScan/HallieBiographyCard.swift:642:17
assign-only property   var.instance                 original                                           VideoScan/HallieFrontDoor.swift:30:13
unused declaration     var.instance                 reason                                             VideoScan/HallieGeneralKnowledgeLane.swift:52:13
unused declaration     var.static                   none                                               VideoScan/HallieModeClassifier.swift:35:20
unused declaration     function.method.instance     shutdown()                                         VideoScan/HallieNeuralSpeech.swift:389:10
assign-only property   var.instance                 removalStatus                                      VideoScan/HallieOutputBuffer.swift:107:26
unused declaration     var.instance                 isAvailable                                        VideoScan/HalliePhonemes.swift:208:9
unused declaration     function.method.static       mentions(_:in:)                                    VideoScan/HalliePlaceFacet.swift:218:17
unused declaration     var.instance                 tally                                              VideoScan/HalliePronunciationDrillList.swift:425:9
assign-only property   var.instance                 name                                               VideoScan/HalliePronunciationDrillList.swift:486:13
assign-only property   var.instance                 key                                                VideoScan/HalliePronunciationDrillList.swift:487:13
assign-only property   var.instance                 kind                                               VideoScan/HalliePronunciationDrillList.swift:488:13
assign-only property   var.instance                 respelling                                         VideoScan/HalliePronunciationDrillList.swift:491:13
assign-only property   var.instance                 alternatives                                       VideoScan/HalliePronunciationDrillList.swift:493:13
assign-only property   var.instance                 status                                             VideoScan/HalliePronunciationDrillList.swift:494:13
assign-only property   var.instance                 source                                             VideoScan/HalliePronunciationDrillList.swift:497:13
assign-only property   var.instance                 origin                                             VideoScan/HalliePronunciationDrillList.swift:499:13
assign-only property   var.instance                 phonemes                                           VideoScan/HalliePronunciationDrillList.swift:500:13
assign-only property   var.instance                 entries                                            VideoScan/HalliePronunciationDrillList.swift:508:9
unused declaration     enum                         Route                                              VideoScan/HallieShellCLI.swift:51:10
unused declaration     function.method.static       route(_:)                                          VideoScan/HallieShellCLI.swift:602:17
assign-only property   var.instance                 note                                               VideoScan/HallieSocialConversation.swift:11:13
unused declaration     var.static                   supportedSurnames                                  VideoScan/HallieSurnameReference.swift:13:16
unused declaration     function.constructor         init(word:saidAs:)                                 VideoScan/HallieTellingMode+Pronunciation.swift:27:9
assign-only property   var.instance                 lastQuery                                          VideoScan/HallieTurnExecutor+Conversation.swift:151:17
assign-only property   var.instance                 resultCount                                        VideoScan/HallieTurnExecutor+Conversation.swift:153:17
unused declaration     function.method.static       needsPresenceRecords(_:)                           VideoScan/HallieTurnExecutor+Conversation.swift:1930:17
unused declaration     function.method.static       preTranslation(question:playAfterAnswer:memory:isKnownPerson:isInnerCircleName:catalogStats:rosterAnswer:lineageAnswer:relationshipsOverview:researchAnswer:selectedRecord:identity:) VideoScan/HallieTurnExecutor+Conversation.swift:661:17
unused declaration     function.method.static       isRosterQuestion(_:)                               VideoScan/HallieTurnExecutor+PeopleTab.swift:173:21
unused declaration     function.method.static       requiresArchive(_:kind:isKnownPerson:)             VideoScan/HallieTurnInterpretation.swift:111:17
unused declaration     function.method.static       definitelyGeneral(_:isKnownPerson:)                VideoScan/HallieTurnInterpretation.swift:153:17
assign-only property   var.instance                 collidedTreePersonIDs                              VideoScan/HallieVitalDates.swift:207:13
unused declaration     function.method.static       resolve(profile:among:graph:)                      VideoScan/HallieVitalDates.swift:315:17
unused declaration     var.static                   loggedDisagreementKeysForTesting                   VideoScan/HallieVitalDates.swift:548:16
unused declaration     var.instance                 loggedKeysForTesting                               VideoScan/HallieVitalDates.swift:573:9
unused declaration     var.instance                 count                                              VideoScan/HoldoutClearStore.swift:185:9
unused declaration     var.instance                 isEmpty                                            VideoScan/HoldoutClearStore.swift:186:9
unused declaration     function.method.instance     isCleared(queueKey:reviewId:)                      VideoScan/HoldoutClearStore.swift:194:10
assign-only property   var.instance                 filename                                           VideoScan/HoldoutClearStore.swift:89:9
unused declaration     function.method.instance     liveCopy(for:isLive:)                              VideoScan/HoldoutCopyResolver.swift:56:10
unused declaration     function.method.static       isUnplayable(meta:)                                VideoScan/HoldoutNavigation.swift:263:17
unused declaration     function.method.static       unplayablePaths(rows:meta:)                        VideoScan/HoldoutNavigation.swift:274:17
unused declaration     var.instance                 clearableReviewIds                                 VideoScan/HoldoutNavigation.swift:405:13
unused declaration     function.method.instance     nextPendingIndex(after:)                           VideoScan/HoldoutReviewQueue.swift:114:10
unused declaration     function.method.static       discover(repoRoot:)                                VideoScan/HoldoutReviewQueue.swift:238:17
unused declaration     function.method.instance     serialized()                                       VideoScan/HoldoutReviewQueue.swift:350:10
unused declaration     function.method.instance     badgeCount(for:)                                   VideoScan/HoldoutReviewQueue.swift:571:10
unused declaration     var.instance                 answeredCount                                      VideoScan/HoldoutReviewQueue.swift:92:9
unused declaration     function.free                pfIdentityCandidates(recordDate:sceneDescriptions:familyBirthdates:familyDeathdates:) VideoScan/IdentityNarrowing.swift:119:18
unused declaration     function.free                pfExtractAgeBuckets(from:)                         VideoScan/IdentityNarrowing.swift:328:18
unused declaration     function.free                pfWordTokens(_:)                                   VideoScan/IdentityNarrowing.swift:395:26
assign-only property   var.instance                 ageAtVideo                                         VideoScan/IdentityNarrowing.swift:47:9
unused declaration     var.instance                 isEmpty                                            VideoScan/IgnoredContentStore.swift:135:9
unused declaration     var.instance                 keyCount                                           VideoScan/IgnoredContentStore.swift:136:9
unused declaration     function.method.instance     contains(partialMD5:sizeBytes:filename:)           VideoScan/IgnoredContentStore.swift:226:10
assign-only property   var.instance                 samplePath                                         VideoScan/IgnoredContentStore.swift:83:9
unused declaration     function.method.instance     inference(for:)                                    VideoScan/KinshipDisplayCenter.swift:183:10
unused declaration     function.method.instance     relationshipsLine(for:among:)                      VideoScan/KinshipDisplayCenter.swift:226:10
unused declaration     function.method.instance     aliasWarning(for:among:)                           VideoScan/KinshipDisplayCenter.swift:241:10
unused declaration     var.instance                 cachedInference                                    VideoScan/KinshipDisplayCenter.swift:93:17
unused declaration     var.instance                 inferenceSignature                                 VideoScan/KinshipDisplayCenter.swift:94:17
unused declaration     var.instance                 inferenceGeneration                                VideoScan/KinshipDisplayCenter.swift:95:17
unused declaration     var.instance                 inferenceBuildCount                                VideoScan/KinshipDisplayCenter.swift:99:22
unused declaration     var.instance                 blocksSave                                         VideoScan/KinshipValidation.swift:344:9
unused declaration     function.method.static       of(profile:bridged:in:now:calendar:)               VideoScan/LifeStatus.swift:110:17
unused declaration     function.method.instance     start(append:)                                     VideoScan/LogSink.swift:90:10
unused declaration     function.method.instance     close()                                            VideoScan/LogSink.swift:93:10
unused declaration     function.free                recentGlobalMLXError()                             VideoScan/MLXSafety.swift:69:6
unused declaration     function.free                clearRecentGlobalMLXError()                        VideoScan/MLXSafety.swift:75:6
unused declaration     function.free                resetMLXInferenceUsedForTesting()                  VideoScan/MLXShutdown.swift:63:6
unused declaration     var.static                   manifestFormatVersion                              VideoScan/MasterArchive.swift:270:16
unused declaration     function.method.static       resolveRelativePath(facts:rootPath:title:fileExists:) VideoScan/MasterArchive.swift:469:17
unused declaration     var.static                   readinessColumn                                    VideoScan/MasterArchive.swift:682:16
unused declaration     var.static                   columnCountLegacy                                  VideoScan/MasterArchive.swift:688:16
unused declaration     var.static                   columnCountV2                                      VideoScan/MasterArchive.swift:689:16
unused declaration     function.method.static       sourceRecordIDs(rootPath:)                         VideoScan/MasterArchive.swift:789:29
unused declaration     function.method.static       remove(volumeOrFolderPath:archiveRootPath:)        VideoScan/MasterArchiveIcon.swift:63:17
assign-only property   var.instance                 familyScore                                        VideoScan/MediaAnalyzer.swift:20:13
assign-only property   var.instance                 familyReasons                                      VideoScan/MediaAnalyzer.swift:21:13
unused declaration     var.static                   GB                                                 VideoScan/MediaBytes.swift:36:16
unused declaration     function.method.static       display(_:)                                        VideoScan/MediaBytes.swift:54:17
unused declaration     function.method.instance     waitForPendingWrites()                             VideoScan/MediaLedger.swift:130:10
unused declaration     function.method.static       mirrorURL(rootPath:)                               VideoScan/MediaLedger.swift:216:17
unused declaration     function.method.instance     events(forFilename:)                               VideoScan/MediaLedger.swift:243:22
unused declaration     function.method.instance     events(forContentKey:)                             VideoScan/MediaLedger.swift:249:22
unused declaration     function.method.instance     events(forRecordID:)                               VideoScan/MediaLedger.swift:254:22
unused declaration     var.instance                 narratedCacheCount                                 VideoScan/MediaLedger.swift:292:9
unused declaration     struct                       MediaPersonLinks                                   VideoScan/MediaPersonLinks.swift:35:8
unused declaration     var.instance                 pingURL                                            VideoScan/MediaStreamResolver.swift:281:9
assign-only property   var.instance                 port                                               VideoScan/MediaStreamResolver.swift:90:13
unused declaration     var.instance                 isPaused                                           VideoScan/MemoryPressure.swift:231:9
unused declaration     function.method.instance     thresholdBytes()                                   VideoScan/MemoryPressure.swift:24:10
unused declaration     function.method.instance     toggle()                                           VideoScan/MemoryPressure.swift:252:10
assign-only property   var.instance                 dbPath                                             VideoScan/MetadataCache.swift:16:9
unused declaration     var.instance                 detail                                             VideoScan/ModelsUI/ArchiveHealth.swift:46:9
unused declaration     var.instance                 icon                                               VideoScan/ModelsUI/ArchiveModels+Presentation.swift:34:9
unused declaration     var.instance                 icon                                               VideoScan/ModelsUI/ArchiveModels+Presentation.swift:62:9
unused declaration     var.instance                 color                                              VideoScan/ModelsUI/CatalogScanTarget.swift:30:9
assign-only property   var.instance                 intent                                             VideoScan/NLQuery.swift:129:9
unused declaration     var.instance                 isEmpty                                            VideoScan/NLQuery.swift:133:9
unused declaration     function.constructor         init(testEmbedder:centroids:params:pauseGate:onProgress:) VideoScan/NativeRecipeScorer.swift:139:5
unused declaration     var.instance                 displayName                                        VideoScan/OllamaQueryTranslator.swift:240:9
unused declaration     function.method.static       ok(_:)                                             VideoScan/OllamaQueryTranslator.swift:29:17
unused declaration     function.method.static       status(_:_:)                                       VideoScan/OllamaQueryTranslator.swift:32:17
unused declaration     function.method.static       down(_:)                                           VideoScan/OllamaQueryTranslator.swift:35:17
unused declaration     function.method.instance     reset()                                            VideoScan/OllamaStructuredOutputCapability.swift:63:10
unused declaration     function.method.static       waitForPendingWrites()                             VideoScan/POIProfileAudit.swift:164:17
unused declaration     function.method.static       entries(directory:)                                VideoScan/POIProfileAudit.swift:179:29
unused declaration     function.method.instance     waitForPendingWrites()                             VideoScan/POIProfileAudit.swift:215:14
assign-only property   var.instance                 at                                                 VideoScan/POIProfileAudit.swift:45:13
assign-only property   var.instance                 action                                             VideoScan/POIProfileAudit.swift:46:13
assign-only property   var.instance                 uuid                                               VideoScan/POIProfileAudit.swift:47:13
assign-only property   var.instance                 display                                            VideoScan/POIProfileAudit.swift:49:13
assign-only property   var.instance                 name                                               VideoScan/POIProfileAudit.swift:50:13
assign-only property   var.instance                 changes                                            VideoScan/POIProfileAudit.swift:51:13
unused declaration     function.method.static       folder(component:in:)                              VideoScan/POIProfileFileStore.swift:46:17
unused declaration     function.method.static       legacyFolder(forName:)                             VideoScan/POIStorage.swift:106:17
assign-only property   var.instance                 finishedAt                                         VideoScan/POIStorage.swift:424:13
assign-only property   var.instance                 backupMethod                                       VideoScan/POIStorage.swift:429:13
assign-only property   var.instance                 complete                                           VideoScan/POIStorage.swift:436:13
assign-only property   var.instance                 foldersBefore                                      VideoScan/POIStorage.swift:440:13
assign-only property   var.instance                 foldersAfter                                       VideoScan/POIStorage.swift:441:13
unused declaration     function.method.static       rollbackUUIDMigration(root:now:)                   VideoScan/POIStorage.swift:896:17
unused declaration     function.method.static       profileURL(forUUID:)                               VideoScan/POIStorage.swift:93:17
unused declaration     function.method.static       profileURL(for:)                                   VideoScan/POIStorage.swift:97:17
unused declaration     function.method.static       data(from:)                                        VideoScan/PerceptualHash.swift:297:17
unused declaration     function.method.static       fingerprint(from:)                                 VideoScan/PerceptualHash.swift:307:17
unused declaration     function.method.static       base64(from:)                                      VideoScan/PerceptualHash.swift:327:17
unused declaration     function.method.static       fingerprint(fromBase64:)                           VideoScan/PerceptualHash.swift:332:17
unused declaration     function.method.instance     clearAll()                                         VideoScan/PersonFinderCache.swift:426:10
unused declaration     var.instance                 count                                              VideoScan/PersonFinderCache.swift:433:9
unused declaration     function.free                pfCatalogSkipPaths(from:)                          VideoScan/PersonFinderCatalogFilter.swift:17:18
assign-only property   var.instance                 decade                                             VideoScan/PersonFinderCompilation.swift:125:9
unused declaration     function.method.instance     pauseAll()                                         VideoScan/PersonFinderModel+JobLifecycle.swift:770:10
unused declaration     function.method.instance     resumeAll()                                        VideoScan/PersonFinderModel+JobLifecycle.swift:774:10
unused declaration     var.instance                 hasActiveJobs                                      VideoScan/PersonFinderModel.swift:490:9
unused declaration     var.instance                 hasPausedJobs                                      VideoScan/PersonFinderModel.swift:491:9
unused declaration     function.method.instance     clearReference()                                   VideoScan/PersonFinderModel.swift:582:10
unused declaration     function.method.instance     saveCurrentPOI()                                   VideoScan/PersonFinderModel.swift:662:10
unused declaration     var.instance                 personDisplayLabel                                 VideoScan/PersonFinderModel.swift:89:9
unused declaration     function.method.instance     deletePOI(named:)                                  VideoScan/PersonFinderModel.swift:931:10
unused declaration     function.method.static       delete(uuid:displayName:)                          VideoScan/PersonFinderTypes.swift:1054:17
unused declaration     function.method.instance     delete()                                           VideoScan/PersonFinderTypes.swift:1070:10
unused declaration     function.method.static       delete(name:)                                      VideoScan/PersonFinderTypes.swift:1079:17
unused declaration     function.method.static       bestCoverFilename(from:)                           VideoScan/PersonFinderTypes.swift:1239:17
unused declaration     var.instance                 shortLabel                                         VideoScan/PersonFinderTypes.swift:130:9
unused declaration     var.instance                 subtitle                                           VideoScan/PersonFinderTypes.swift:139:9
unused declaration     var.instance                 duration                                           VideoScan/PersonFinderTypes.swift:1472:9
unused declaration     var.instance                 capabilitySummary                                  VideoScan/PersonFinderTypes.swift:152:9
unused declaration     var.instance                 requirementsSummary                                VideoScan/PersonFinderTypes.swift:161:9
unused declaration     var.instance                 symbolName                                         VideoScan/PersonFinderTypes.swift:170:9
unused declaration     function.method.instance     toProfile(coverImageFilename:notes:aliases:)       VideoScan/PersonFinderTypes.swift:352:10
assign-only property   var.instance                 legacyFolderName                                   VideoScan/PersonFinderTypes.swift:513:9
assign-only property   var.instance                 kinshipsQuarantined                                VideoScan/PersonFinderTypes.swift:586:9
unused declaration     var.instance                 displayFullName                                    VideoScan/PersonFinderTypes.swift:665:9
unused declaration     function.method.instance     saveRenaming(from:)                                VideoScan/PersonFinderTypes.swift:884:10
unused declaration     var.instance                 cachedEntryCount                                   VideoScan/PersonPhotoResolver.swift:401:9
assign-only property   var.instance                 source                                             VideoScan/PersonPhotoResolver.swift:60:9
assign-only property   var.instance                 candidateEvaluationCount                           VideoScan/PersonPhotoResolver.swift:99:13
assign-only property   var.instance                 code                                               VideoScan/PersonWarningPopover.swift:29:13
unused declaration     function.method.static       completion(for:)                                   VideoScan/PreservationChecklist.swift:105:17
unused declaration     function.method.static       nextAction(for:)                                   VideoScan/PreservationChecklist.swift:112:17
unused declaration     var.instance                 count                                              VideoScan/PreviewFrameRoute.swift:110:9
unused declaration     var.static                   maxCandidates                                      VideoScan/PreviewFrameScorer.swift:194:16
unused declaration     struct                       ModelBackedCatalogSource                           VideoScan/PreviewSweepAdapters.swift:73:8
unused declaration     var.instance                 isSweeping                                         VideoScan/PreviewSweepService.swift:157:9
unused declaration     function.method.instance     stop()                                             VideoScan/PreviewSweepService.swift:209:10
unused declaration     var.instance                 current                                            VideoScan/ProbeGroupBounding.swift:47:9
unused declaration     var.instance                 maxLive                                            VideoScan/ProbeGroupBounding.swift:48:9
unused declaration     var.instance                 observations                                       VideoScan/ProbeGroupBounding.swift:49:9
assign-only property   var.instance                 completionTask                                     VideoScan/PromoteToArchiveJob.swift:129:22
assign-only property   var.instance                 filename                                           VideoScan/PromoteToArchiveJob.swift:74:13
unused declaration     var.static                   defaultLimit                                       VideoScan/PronunciationVariations.swift:48:16
unused declaration     function.method.static       candidates(for:hint:respellings:limit:gold:)       VideoScan/PronunciationVariations.swift:58:17
unused declaration     var.static                   movedEarlierReason                                 VideoScan/PruneApplyJob.swift:164:16
unused declaration     function.method.static       droppedLine(title:count:bytes:forQuit:)            VideoScan/PruneApplyJob.swift:311:29
assign-only property   var.instance                 publishedURL                                       VideoScan/RebuildAudioJob.swift:201:22
unused declaration     function.method.static       reconcile(records:allCatalogRecords:sourceVolumeRootPath:destinationRoot:sourceFiles:destFiles:skipDupsOnOtherVolumes:skipAlreadyRelocated:resolveVolumeSafety:hash:) VideoScan/RelocateReconcile.swift:388:17
assign-only property   var.instance                 sourcePath                                         VideoScan/RelocateSummary.swift:85:13
unused declaration     var.instance                 refusals                                           VideoScan/RemoteViewerMode.swift:101:9
unused declaration     function.method.instance     reset(sink:)                                       VideoScan/RemoteViewerMode.swift:67:10
unused declaration     function.method.static       refusedForProfile(named:)                          VideoScan/ResearchPerson.swift:138:17
unused declaration     struct                       FixtureResearchFetcher                             VideoScan/ResearchSources.swift:146:8
assign-only property   var.instance                 fromCache                                          VideoScan/ResearchSources.swift:45:9
unused declaration     function.method.instance     keysWithDossiers()                                 VideoScan/ResearchStore.swift:144:10
unused declaration     function.method.static       exists(for:)                                       VideoScan/ScanCheckpoint.swift:110:17
unused declaration     function.method.static       age(for:)                                          VideoScan/ScanCheckpoint.swift:114:17
unused declaration     function.method.static       extractMetadata(probe:into:)                       VideoScan/ScanEngine.swift:78:17
unused declaration     function.method.static       restore(existing:savedTargetsKey:savedDatesKey:savedPhasesKey:savedRolesKey:savedTrustKey:savedFilesystemKey:savedMediaTechKey:savedPurchaseYearKey:savedCapacityKey:savedNotesKey:savedRetiredAtKey:savedRetiredReasonKey:savedRetiredWitnessesKey:) VideoScan/ScanTargetPersistence.swift:71:17
unused declaration     function.method.static       quarantineAndDelete(_:hooks:)                      VideoScan/SignatureVerification.swift:825:17
unused declaration     var.instance                 lifecycleCountersForTesting                        VideoScan/StallMonitor.swift:114:9
unused declaration     var.instance                 isRunningForTesting                                VideoScan/StallMonitor.swift:121:9
unused declaration     function.method.static       enforcingFileExtension(_:preset:)                  VideoScan/TranscodeDestination.swift:66:29
unused declaration     var.instance                 line                                               VideoScan/TreeIdentityCenter.swift:49:13
unused declaration     var.instance                 isAutoAcceptable                                   VideoScan/TreeIdentityDeriver.swift:128:9
assign-only property   var.instance                 deathdate                                          VideoScan/TreeIdentityDeriver.swift:143:9
unused declaration     function.constructor         init(graph:profiles:ownerName:ownerFamilySearchID:) VideoScan/TreeIdentityDeriver.swift:275:5
assign-only property   var.instance                 sex                                                VideoScan/TreeIdentityDeriver.swift:52:9
unused declaration     var.instance                 profile                                            VideoScan/TreeIdentityShowInTree.swift:104:13
unused declaration     var.instance                 refusal                                            VideoScan/TreeIdentityShowInTree.swift:108:13
unused declaration     function.method.static       pinnedLine(profileName:candidate:)                 VideoScan/TreeIdentityShowInTree.swift:76:17
unused declaration     function.method.static       usingLine(profileName:candidate:)                  VideoScan/TreeIdentityShowInTree.swift:81:17
unused declaration     var.instance                 count                                              VideoScan/TrimSheet.swift:74:9
unused declaration     var.instance                 fullPath                                           VideoScan/UnifiedReviewSession.swift:44:9
unused declaration     var.instance                 filename                                           VideoScan/UnifiedReviewSession.swift:51:9
unused declaration     var.instance                 isBlind                                            VideoScan/UnifiedReviewSession.swift:60:9
unused declaration     function.method.static       candidates(in:)                                    VideoScan/UnrelatedAudioPurge.swift:170:17
unused declaration     function.method.static       count(in:)                                         VideoScan/UnrelatedAudioPurge.swift:189:17
unused declaration     var.instance                 places                                             VideoScan/UserPlaceRoster.swift:41:9
unused declaration     function.method.static       compute(records:)                                  VideoScan/UserPlaceRoster.swift:71:17
assign-only property   var.instance                 expectedDigest                                     VideoScan/VerifyArchiveCopiesJob.swift:241:13
assign-only property   var.instance                 actualDigest                                       VideoScan/VerifyArchiveCopiesJob.swift:243:13
assign-only property   var.instance                 writeSkipped                                       VideoScan/VerifyArchiveCopiesJob.swift:246:13
unused declaration     function.method.static       isSuspiciouslyTiny(fileSizeBytes:durationSeconds:) VideoScan/VerifyAudioProbe.swift:222:17
assign-only property   var.instance                 fileSizeBytes                                      VideoScan/VerifyAudioProbe.swift:81:9
unused declaration     var.instance                 archivedDateText                                   VideoScan/VideoRecord+ArchivedAt.swift:53:9
unused declaration     function.method.instance     setArchiveStage(_:for:)                            VideoScan/VideoScanModel+Archive.swift:20:10
unused declaration     function.method.instance     addBackup(_:to:)                                   VideoScan/VideoScanModel+Archive.swift:28:10
assign-only property   var.instance                 outcomes                                           VideoScan/VideoScanModel+ArchiveAngelBufferHygiene.swift:122:9
assign-only property   var.instance                 removed                                            VideoScan/VideoScanModel+ArchiveAngelBufferHygiene.swift:91:13
assign-only property   var.instance                 bytesFreed                                         VideoScan/VideoScanModel+ArchiveAngelBufferHygiene.swift:93:13
assign-only property   var.instance                 companionsRetired                                  VideoScan/VideoScanModel+ArchiveAngelBufferHygiene.swift:96:13
assign-only property   var.instance                 failure                                            VideoScan/VideoScanModel+ArchiveAngelBufferHygiene.swift:97:13
unused declaration     function.method.instance     applyAudioTranscripts(_:model:)                    VideoScan/VideoScanModel+AudioTranscript.swift:104:10
unused declaration     function.method.instance     applyAudioTranscript(_:modelID:to:)                VideoScan/VideoScanModel+AudioTranscript.swift:36:10
unused declaration     function.method.instance     applyAudioTranscript(_:to:model:)                  VideoScan/VideoScanModel+AudioTranscript.swift:79:10
unused declaration     function.method.static       entries(rootPath:)                                 VideoScan/VideoScanModel+BackupAttestations.swift:151:29
assign-only property   var.instance                 records                                            VideoScan/VideoScanModel+BackupAttestations.swift:184:9
assign-only property   var.instance                 flush                                              VideoScan/VideoScanModel+BackupAttestations.swift:185:9
unused declaration     function.method.instance     protectionSummary(for:isOnline:)                   VideoScan/VideoScanModel+BackupAttestations.swift:293:10
unused declaration     function.method.static       protectionFamilies(batch:catalog:isArchiveCopy:isOnline:) VideoScan/VideoScanModel+BackupAttestations.swift:306:17
unused declaration     struct                       CatalogImportResult                                VideoScan/VideoScanModel+CatalogImportExport.swift:21:12
unused declaration     function.method.instance     exportCatalog(to:)                                 VideoScan/VideoScanModel+CatalogImportExport.swift:39:10
unused declaration     function.method.instance     importCatalog(from:)                               VideoScan/VideoScanModel+CatalogImportExport.swift:72:10
unused declaration     var.instance                 bytesToRead                                        VideoScan/VideoScanModel+ContentHashBackfill.swift:55:13
assign-only property   var.instance                 fullPath                                           VideoScan/VideoScanModel+DateInference.swift:521:13
assign-only property   var.instance                 fullPath                                           VideoScan/VideoScanModel+DateInference.swift:532:13
assign-only property   var.instance                 conflictingHashes                                  VideoScan/VideoScanModel+DateInference.swift:542:13
assign-only property   var.instance                 sidecar                                            VideoScan/VideoScanModel+DateInference.swift:552:13
unused declaration     function.method.static       unwoundSidecarDecoder()                            VideoScan/VideoScanModel+DateInference.swift:746:17
unused declaration     function.method.static       reapplyUnwoundDates(from:to:)                      VideoScan/VideoScanModel+DateInference.swift:760:17
unused declaration     function.method.static       reapplyUnwoundDates(_:reanchored:to:)              VideoScan/VideoScanModel+DateInference.swift:770:17
unused declaration     function.method.instance     deleteDuplicates(onVolume:verificationHooks:)      VideoScan/VideoScanModel+Duplicates.swift:243:10
unused declaration     function.method.instance     applyDetectedPeople(matches:person:)               VideoScan/VideoScanModel+FamilyTagging.swift:167:10
unused declaration     var.instance                 confirmedJunkRecords                               VideoScan/VideoScanModel+JunkDelete.swift:446:9
unused declaration     var.instance                 isPermanent                                        VideoScan/VideoScanModel+MasterArchive.swift:100:13
unused declaration     var.instance                 masterArchiveTargetID                              VideoScan/VideoScanModel+MasterArchive.swift:342:9
unused declaration     function.method.instance     clearMasterArchive()                               VideoScan/VideoScanModel+MasterArchive.swift:483:10
assign-only property   var.instance                 recordsCleaned                                     VideoScan/VideoScanModel+NotesRepair.swift:40:13
assign-only property   var.instance                 linesMoved                                         VideoScan/VideoScanModel+NotesRepair.swift:42:13
assign-only property   var.instance                 humanNotesKept                                     VideoScan/VideoScanModel+NotesRepair.swift:44:13
assign-only property   var.instance                 backupPath                                         VideoScan/VideoScanModel+NotesRepair.swift:46:13
unused declaration     function.method.instance     cancelledProbeRecord(url:)                         VideoScan/VideoScanModel+ProbeEngine.swift:634:10
unused declaration     function.method.instance     probeFileWithTimeout(url:prefetchToRAM:ramPath:skipHashing:scanRootPath:) VideoScan/VideoScanModel+ProbeEngine.swift:708:10
unused declaration     function.method.instance     applyPrune(shown:selected:recordIDs:options:batchID:mode:hooks:) VideoScan/VideoScanModel+PruneApply.swift:659:10
unused declaration     function.method.static       suggestDestinationName(forSourceVolumeName:now:)   VideoScan/VideoScanModel+Relocate.swift:131:29
unused declaration     function.method.instance     maybeOfferRetire(for:)                             VideoScan/VideoScanModel+Relocate.swift:747:10
unused declaration     enum                         RelocateError                                      VideoScan/VideoScanModel+Relocate.swift:83:6
unused declaration     function.method.static       shouldOfferRetire(volumeRootPath:in:)              VideoScan/VideoScanModel+RetireVolume.swift:100:29
unused declaration     function.method.static       manuallyDeletedOn(volumeRootPath:in:)              VideoScan/VideoScanModel+RetireVolume.swift:62:29
unused declaration     function.method.static       originatedOnCount(volumeRootPath:in:)              VideoScan/VideoScanModel+RetireVolume.swift:76:29
assign-only property   var.instance                 retainedStale                                      VideoScan/VideoScanModel+ScanMerge.swift:105:9
assign-only property   var.instance                 retainedNoSnapshot                                 VideoScan/VideoScanModel+ScanMerge.swift:117:9
unused declaration     function.method.static       matchMovedFiles(added:candidates:)                 VideoScan/VideoScanModel+ScanMergeMoveIdentity.swift:158:29
unused declaration     var.instance                 unscannedTargetCount                               VideoScan/VideoScanModel+ScanTargets.swift:40:9
unused declaration     function.method.static       isUnscannedRemovable(_:)                           VideoScan/VideoScanModel+ScanTargets.swift:47:17
unused declaration     function.method.instance     cleanupUnscannedTargets()                          VideoScan/VideoScanModel+ScanTargets.swift:61:10
unused declaration     function.method.instance     applyCaptions(_:model:)                            VideoScan/VideoScanModel+SceneCaptions.swift:78:10
unused declaration     function.method.instance     runFFProbe(url:)                                   VideoScan/VideoScanModel+Thumbnail.swift:177:22
assign-only property   var.instance                 id                                                 VideoScan/VideoScanModel+TrashSelection.swift:43:17
unused declaration     function.method.instance     resetLooksMovedDebounce(forVolume:)                VideoScan/VideoScanModel+UpdateCatalog.swift:461:10
assign-only property   var.instance                 dominantDestinationVolume                          VideoScan/VideoScanModel+VolumeRelocateIndicator.swift:53:13
assign-only property   var.instance                 dominantDestinationCount                           VideoScan/VideoScanModel+VolumeRelocateIndicator.swift:55:13
assign-only property   var.instance                 migratedCount                                      VideoScan/VideoScanModel+VolumeRenameMigration.swift:212:9
assign-only property   var.instance                 lastDiscoveryAudit                                 VideoScan/VideoScanModel.swift:838:9
assign-only property   var.instance                 backfillTask                                       VideoScan/VideoScanModel.swift:847:9
assign-only property   var.instance                 totalSourceBytes                                   VideoScan/VolumeCompare.swift:25:9
assign-only property   var.instance                 isOther                                            VideoScan/VolumeDashboard.swift:100:9
unused declaration     function.method.instance     awaitPendingProbes()                               VideoScan/VolumeReachability.swift:112:10
unused declaration     function.method.static       awaitPendingProbesForTesting()                     VideoScan/VolumeReachability.swift:308:26
unused declaration     var.instance                 isWorkerRunning                                    VideoScan/WhisperWorkerTranscriber.swift:346:9
unused declaration     function.constructor         init(name:kind:date:)                              VideoScanCore/Sources/VideoScanCore/ArchiveModels.swift:77:12
unused declaration     function.method.static       summary(_:)                                        VideoScanCore/Sources/VideoScanCore/BackupAttestation.swift:350:24
unused declaration     var.instance                 latestBackupAttestations                           VideoScanCore/Sources/VideoScanCore/BackupAttestation.swift:389:16
unused declaration     function.method.instance     backupAttestation(for:)                            VideoScanCore/Sources/VideoScanCore/BackupAttestation.swift:393:17
unused declaration     function.method.instance     stampMatches(path:)                                VideoScanCore/Sources/VideoScanCore/ContentFixity.swift:153:17
redundant public       enum                         CyberBrainValidator                                VideoScanCore/Sources/VideoScanCore/CyberBrainLoader.swift:30:13
redundant public       function.method.static       validate(_:)                                       VideoScanCore/Sources/VideoScanCore/CyberBrainLoader.swift:31:24
unused declaration     function.method.static       researchURL(of:)                                   VideoScanCore/Sources/VideoScanCore/CyberBrainWriter.swift:143:24
assign-only property   var.instance                 personID                                           VideoScanCore/Sources/VideoScanCore/CyberBrainWriter.swift:182:20
assign-only property   var.instance                 sourceID                                           VideoScanCore/Sources/VideoScanCore/CyberBrainWriter.swift:185:20
assign-only property   var.instance                 createdPerson                                      VideoScanCore/Sources/VideoScanCore/CyberBrainWriter.swift:188:20
redundant public       enum                         EmbeddedDateSanity                                 VideoScanCore/Sources/VideoScanCore/EmbeddedCreationDate.swift:177:13
redundant public       var.static                   earliestPlausibleYear                              VideoScanCore/Sources/VideoScanCore/EmbeddedCreationDate.swift:180:23
redundant public       var.static                   futureSlack                                        VideoScanCore/Sources/VideoScanCore/EmbeddedCreationDate.swift:183:23
redundant public       function.method.static       accept(_:now:)                                     VideoScanCore/Sources/VideoScanCore/EmbeddedCreationDate.swift:187:24
redundant public       enum                         EmbeddedDateParser                                 VideoScanCore/Sources/VideoScanCore/EmbeddedCreationDate.swift:38:13
redundant public       function.method.static       parse(_:)                                          VideoScanCore/Sources/VideoScanCore/EmbeddedCreationDate.swift:52:24
assign-only property   var.instance                 localDroppedLineCount                              VideoScanCore/Sources/VideoScanCore/FamilyGraphCompiledStore.swift:170:20
assign-only property   var.instance                 totalDroppedLineCount                              VideoScanCore/Sources/VideoScanCore/FamilyGraphCompiledStore.swift:171:20
unused declaration     function.method.instance     rollback()                                         VideoScanCore/Sources/VideoScanCore/FamilyGraphCompiledStore.swift:786:17
assign-only property   var.instance                 reason                                             VideoScanCore/Sources/VideoScanCore/FamilyTreeResearchLinks.swift:30:20
unused declaration     function.method.instance     of(_:)                                             VideoScanCore/Sources/VideoScanCore/FamilyTreeVerification.swift:88:21
unused declaration     function.free                previewSweepCandidates(from:isReachable:)          VideoScanCore/Sources/VideoScanCore/FileBackedCatalogSource.swift:30:13
unused declaration     var.instance                 catalogURL                                         VideoScanCore/Sources/VideoScanCore/FileBackedCatalogSource.swift:51:16
unused declaration     var.instance                 isReachable                                        VideoScanCore/Sources/VideoScanCore/FileBackedCatalogSource.swift:55:16
unused declaration     function.constructor         init(catalogURL:isReachable:)                      VideoScanCore/Sources/VideoScanCore/FileBackedCatalogSource.swift:57:12
unused declaration     function.method.instance     eligibleCandidates()                               VideoScanCore/Sources/VideoScanCore/FileBackedCatalogSource.swift:63:17
unused declaration     enum                         GauntletFixturePlan                                VideoScanCore/Sources/VideoScanCore/GauntletFixturePlan.swift:27:13
unused declaration     struct                       CommonAncestor                                     VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+CommonAncestors.swift:16:19
unused declaration     function.method.instance     commonAncestors(of:and:limit:)                     VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+CommonAncestors.swift:44:17
unused declaration     function.method.instance     descentPath(from:to:)                              VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+Descent.swift:157:17
unused declaration     function.method.instance     relationshipLabel(from:to:possessive:)             VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+Descent.swift:200:17
unused declaration     var.instance                 depths                                             VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+Descent.swift:98:20
unused declaration     var.instance                 hasBuiltIndex                                      VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+Index.swift:673:16
unused declaration     function.method.instance     people(withGivenName:)                             VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+Index.swift:775:17
assign-only property   var.instance                 undatedWalked                                      VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+Lineage.swift:130:20
unused declaration     var.instance                 allPeople                                          VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+Lineage.swift:221:20
unused declaration     function.method.static       personHasGivenName(_:forms:)                       VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph+NameIndex.swift:75:24
unused declaration     enum                         GedcomSyntheticPedigree                            VideoScanCore/Sources/VideoScanCore/GedcomSyntheticPedigree.swift:19:13
assign-only property   var.instance                 familySearchID                                     VideoScanCore/Sources/VideoScanCore/PersonFactOverlay.swift:89:20
unused declaration     function.method.static       parseTierFilename(_:)                              VideoScanCore/Sources/VideoScanCore/PreviewDiskCache.swift:237:24
unused declaration     var.static                   maxStripOffsetMillis                               VideoScanCore/Sources/VideoScanCore/PreviewDiskCache.swift:363:23
assign-only property   var.instance                 key                                                VideoScanCore/Sources/VideoScanCore/PreviewSweepPlan.swift:107:16
redundant public       enum                         PreviewSweepPlanner                                VideoScanCore/Sources/VideoScanCore/PreviewSweepPlan.swift:149:13
redundant public       function.method.static       buildCacheIndex(files:)                            VideoScanCore/Sources/VideoScanCore/PreviewSweepPlan.swift:157:24
redundant public       function.method.static       workItems(candidates:index:)                       VideoScanCore/Sources/VideoScanCore/PreviewSweepPlan.swift:220:24
assign-only property   var.instance                 reason                                             VideoScanCore/Sources/VideoScanCore/PrunePlan.swift:500:20
assign-only property   var.instance                 kept                                               VideoScanCore/Sources/VideoScanCore/PrunePlan.swift:624:20
unused declaration     var.instance                 defaultSelection                                   VideoScanCore/Sources/VideoScanCore/PrunePlan.swift:674:20
assign-only property   var.instance                 trashCount                                         VideoScanCore/Sources/VideoScanCore/PrunePlan.swift:850:16
unused declaration     var.instance                 trashFiles                                         VideoScanCore/Sources/VideoScanCore/PrunePlan.swift:862:16
redundant public       enum                         FilenameDatePattern                                VideoScanCore/Sources/VideoScanCore/RecordDateResolver.swift:224:13
redundant public       struct                       Match                                              VideoScanCore/Sources/VideoScanCore/RecordDateResolver.swift:226:19
redundant public       var.instance                 year                                               VideoScanCore/Sources/VideoScanCore/RecordDateResolver.swift:227:20
redundant public       var.instance                 month                                              VideoScanCore/Sources/VideoScanCore/RecordDateResolver.swift:228:20
redundant public       var.instance                 day                                                VideoScanCore/Sources/VideoScanCore/RecordDateResolver.swift:229:20
redundant public       var.instance                 precision                                          VideoScanCore/Sources/VideoScanCore/RecordDateResolver.swift:230:20
redundant public       function.method.static       match(_:now:)                                      VideoScanCore/Sources/VideoScanCore/RecordDateResolver.swift:298:24
unused declaration     var.instance                 isRemoteMount                                      VideoScanCore/Sources/VideoScanCore/ScanContext.swift:75:16
unused declaration     function.free                analyzeValueScore(durationSeconds:hasAudio:hasLegacyCodec:container:fileMTime:) VideoScanCore/Sources/VideoScanCore/UnplayableLegacyCodecs.swift:117:13
redundant public       function.free                unplayableLegacyReason(videoCodec:audioCodec:)     VideoScanCore/Sources/VideoScanCore/UnplayableLegacyCodecs.swift:75:13
unused declaration     function.constructor         init(legacyRawValue:)                              VideoScanCore/Sources/VideoScanCore/VolumeStatusEnums.swift:156:12
unused declaration     function.method.static       isJourneyStampLine(_:)                             VideoScanCore/Sources/VideoScanCore/WorkflowTags.swift:143:24
```

## Scope caveat: VideoScanCore

The Xcode scheme builds only the app and its test bundle. VideoScanCore's own targets (`videoscan-preview-sweep`, `videoscan-tree-ingest`, `VideoScanCoreTests`) are not indexed. Every VideoScanCore finding (98 in run B) is low-confidence; `PreviewSweepCLIOptions`/`PreviewSweepCLIRunner` are confirmed false positives (used by `Sources/videoscan-preview-sweep/main.swift`). To cover the package correctly, run a separate `periphery scan --package-path VideoScan/VideoScanCore`.

## Delete / trash / archive paths: results

None of the flagged items is a proven safety gate that has come unwired. What turned up, most important first:

1. `RelocateError` (VideoScanModel+Relocate.swift:83) is never thrown in production. `destinationUnwritable` is never constructed. The other three cases are constructed only in RelocateScopeTests' equality test. The doc comment calls it "the error surface for the public relocate entry point", but that preflight (source reachable, destination writable, enough space, non-empty scope) does not exist at model level. The only space check found is display-side (RelocateSheet.swift:101). Relocate copies files and does not delete them, so this is about data landing safely, not about data loss. It is a documented guard that is not in the code.
2. `SignatureVerification.candidateDisclaimer` (SignatureVerification.swift:1007) is never used. Its doc says "Used wherever the UI reports a duplicate, so the interface never repeats the overclaim". So the text meant to stop the UI overclaiming about duplicates is not shown anywhere. The safety claim itself ("every byte is compared before anything is deleted") is enforced in DeleteDuplicatesJob, which calls `duplicateRefusalNote` directly.
3. `CatalogToolbar.showJunkConfirmSheet` (CatalogToolbar.swift:138) is never set to true, so the Delete Confirmed Junk confirm and result sheets attached at CatalogToolbar.swift:695-720 can never be shown. That delete entry point now lives in TriageView.swift:372. This is dead UI on a delete path, not a missing check.
4. `PruneApplyJob.refuseToStart(reason:)` (PruneApplyJob.swift:378) is dead on purpose. The 9/22 queue change (39956d86) replaced refusal with queuing, and PruneApplyTests.swift:1351 checks that the refusal string is gone. The other refusal path at PruneApplyJob.swift:473 is still wired.
5. `VideoScanModel.refusalNote(_:keeper:)` (VideoScanModel+Duplicates.swift:853) is a thin wrapper nobody calls. DeleteDuplicatesJob calls `duplicateRefusalNote` directly at 5 sites, so the refusal logic is wired.
6. The following are copies kept for display that nothing reads. They are not gates, because the matching decision fields are read:
   - `PrunePlan.CopyRef.fixityVerified` (PrunePlan.swift:465). The gate reads the snapshot at :1006.
   - `CopyInstance.isRetired` / `isMasterArchive` (CopyFamilyAssessor.swift:156-157). Rule 6 reads `CopyFamilyInput.isRetired` at :599.
   - `VolumeCompareResult.alreadySafe`. Only the count is used.
   - `PruneByteCheck.archiveID` / `filename`, `PruneProof.copyID`, and `PruneHeld.line`.
7. `quitInformativeText(running:…)` (DeleteDuplicatesJob.swift:2222): the `running` parameter is ignored, so the quit dialog never states how many jobs are running.
8. `showCoverArtMusicPurgeSheet` / `showUnrelatedAudioPurgeSheet` (VideoScanModel.swift:1359/1368) and their candidate helpers are left over from a superseded version. The comment at :1377 says the new purge surface replaces them.

## Curated high-confidence list (run B: app target, not referenced from tests either)

1. PruneApplyJob.refuseToStart(reason:): PruneApplyJob.swift:378
2. VideoScanModel.refusalNote(_:keeper:): VideoScanModel+Duplicates.swift:853
3. CatalogToolbar showJunkConfirmSheet and the confirm and result sheets it drives: CatalogToolbar.swift:138, 695-720
4. showCoverArtMusicPurgeSheet, showUnrelatedAudioPurgeSheet: VideoScanModel.swift:1359, 1368
5. coverArtMusicPurgeCandidates and CoverArtMusicPurge.candidates(in:): VideoScanModel+CoverArtMusicPurge.swift:49, CoverArtMusicPurge.swift:68
6. unrelatedAudioPurgeCount / unrelatedAudioPurgeCandidates: VideoScanModel+UnrelatedAudioPurge.swift:41, 53
7. RelocateError (the whole enum, or wire it up): VideoScanModel+Relocate.swift:83
8. SignatureVerification.candidateDisclaimer (or wire it up): SignatureVerification.swift:1007
9. StageBadge_Removed: DossierDashboardView+Rows.swift:312
10. DialRing, StatRow, StatusBadge: DossierDashboardView+Subviews.swift:20, 61, 111
11. MiniRing and subText: DossierToolbarChip.swift:107, 97
12. ArchivistChatWindow legacy routing block. There are 7 methods: handleGeneralQuestion, declineForRecompile, answerDate, answerPlace, answerWhoIs, appendProfileAmbiguity, handleKinship. Location: ArchivistChatWindow.swift:1668-1887
13. ArchiveAngelDetailView chipColor/icon/background: ArchiveAngelDetailView.swift:151, 412, 421
14. CopyFamilyAssessor signatureKey(_:), losslessAudioCodecs, CopyRole.isOriginal: CopyFamilyAssessor.swift:539, 242, 146
15. ConfirmedJunkSplit.offlineBytes: VideoScanModel+JunkDelete.swift:463
16. PruneHeld.line: VideoScanModel+PruneApply.swift:173
17. MediaBytes KB/MB/TB/PB: MediaBytes.swift:34-38
18. RAMAssetLoader isEnabled / maxFileSizeBytes / warm(fileURL:): RAMAssetLoader.swift:202-207
19. Unused @Environment(\.openWindow) in 7 views: CatalogToolbar:12, CleanupSheet:51, RipAllFramesSheet:27, TranscodeSheet:10, TriageView:91, TrimSheet:107, VerifyAudioSheet:79
20. Unused @State flags: showAskPopover (CatalogToolbar:148), showCombineSheet/showDashboard/showInspector (ContentView:295, 324, 325), showSummary (ConfirmPersonSheet:151), showDetails (AssessCopiesDetailView:38), showCopies (FileJourneySheet:17), showAdvanced (FamilySearchPullSheet:25), expanded/showAtRisk (VolumeProvenanceSheet:221, 89), showDegraded/showSalvageFailed (RelocateSummarySheet:41, 45), substitutionsExpanded/blockedExpanded (CombinePreflightSheet:22-23)
21. MasterOnlyCaption: ViewerModeViews.swift:63
22. ReferenceFaceCard: PersonFinderSubviews.swift:28
23. CatalogSizeTotalsBox and totalTooltip: CatalogSizeTotals.swift:273, 249
24. RecordDateInference struct and extension: DateTriangulation.swift:42, 48
25. Unused `import VideoScanCore` in 7 files: ArchiveDateEntry, HallieGalleryAnswer, HallieOfferAcceptance, HalliePhotoCaption, HallieShellCLI+Render, HallieWebPoster, HallieWebProxy

Skipped as likely false positives or low-confidence:
- All VideoScanCore findings (targets not indexed).
- Codable assign-only properties.
- The @AppStorage `ollamaHost` in 2 files (a persisted settings key).
- LLDB/test hooks: `resetForTesting` and `clearAll`.
- Anything reported only in run C (these are referenced from tests).
