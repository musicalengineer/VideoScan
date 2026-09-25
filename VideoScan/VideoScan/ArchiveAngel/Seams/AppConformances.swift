// AppConformances.swift
// EVERY place the app plugs into the Archive Angel's seams
// (Seams/AngelSeams.swift), in one file — the Angel's whole outbound
// surface is this file plus AngelEnvironment.swift. The boundary sensor
// exempts exactly these seam files from its outbound rules.
//
// Most requirements are satisfied by members the model and the MFO center
// already had (record(forID:), record(forPath:), buildPromotePlan…); the
// bodies below are the few that were written inline elsewhere before S2:
//   • angelLog / isCatalogBusyForAngel — the sweep wiring's closures
//     (was VideoScanModel+ArchiveAngelSweep.configureArchiveAngelSweep);
//   • showInCatalog(recordID:) / showInCatalog(focus:label:) — the tab
//     navigation (was ArchiveAngelRowActions.navigate and
//     ArchiveAngelAssessmentPanel.showCandidatesInCatalog, verbatim);
//   • isBusy — the sweep's busy gate (was the `is ArchiveAngelJob ||
//     is PromoteToArchiveJob` closure VideoScanApp installed on the model);
//   • startArchiveAngelByUser — the start sheet's and the catalog's
//     `startedByUser { $0.startArchiveAngel(…) }`.

import Foundation
import VideoScanCore

extension VideoScanModel: AngelCatalog, AngelNavigator, AngelArchive, AngelLedger {

    // MARK: AngelCatalog

    var isCatalogBusyForAngel: Bool { isScanning || isCombining }

    func isRecommendableNow(_ rec: VideoRecord) -> Bool {
        !rec.isPurged && !rec.isSetAside && !rec.isSuperseded && !promoteWouldRefusePermanently(rec)
    }

    func angelLog(_ line: String) {
        log(line)
        appLog.write(line)
    }

    /// The preview sweep's gate is the one every interactive catalog path
    /// pings (`previewSweep.noteUserInteraction`); Angel Checks read it.
    var lastUserInteractionAt: CFAbsoluteTime? { previewSweep.gate.lastInteraction }

    /// Keep footage current (§5): ONE pass over the active records.
    func footageCurrency() -> (grouped: Int, newestScan: Date?) {
        var grouped = 0
        var newest: Date?
        for r in records where !r.isPurged {
            guard let f = r.footage else { continue }
            grouped += 1
            if newest.map({ f.scannedAt > $0 }) ?? true { newest = f.scannedAt }
        }
        return (grouped, newest)
    }

    /// Show Copies… (S4): the same active set the retired AssessCopiesJob
    /// walked (`pfActiveRecords(model.records)`).
    func activeRecordsForCopyFamily() -> [VideoRecord] {
        pfActiveRecords(records)
    }

    /// The prepare step's "already balanced?" question (S4 fix): active
    /// records the Balance Audio job catalogued from `record`.
    func catalogedBalancedCopies(of record: VideoRecord) -> [VideoRecord] {
        let id = record.id
        return records.filter {
            $0.derivedFrom == id && $0.derivationKind == BalanceAudioFix.derivationKind
                && !$0.isPurged && !$0.isSetAside && !$0.isSuperseded
        }
    }

    // MARK: AngelNavigator

    /// Same steps as ArchiveView+Table.showInCatalog, without the view:
    /// focus the record (and its duplicate group), select it, switch the
    /// main window to the Catalog tab and bring it forward.
    func showInCatalog(recordID id: UUID) {
        focusedMediaIDs = focusSet(for: id)
        pendingCatalogSelection = id
        pendingCatalogPairMode = false
        UserDefaults.standard.set(1, forKey: "selectedTab")
        MainWindowHelper.shared.openMainWindow()
    }

    /// Focus the Catalog on a set (e.g. every grade A and B record) under
    /// a label, nothing selected.
    func showInCatalog(focus ids: Set<UUID>, label: String) {
        focusedMediaIDs = ids
        pendingFocusLabel = label
        pendingCatalogSelection = nil
        pendingCatalogPairMode = false
        UserDefaults.standard.set(1, forKey: "selectedTab")
        MainWindowHelper.shared.openMainWindow()
    }
}

extension MediaFileOperationsCenter: AngelJobRunner {

    /// AngelJobRunner: an Archive Angel or Promote job is active — the
    /// Angel's scoring sweep parks behind it. (NOT "any job is running".)
    var isBusy: Bool {
        jobs.contains { $0.state.isActive && ($0 is ArchiveAngelJob || $0 is PromoteToArchiveJob) }
    }

    /// A batch the user asked for — claims user origin so the MFO window
    /// comes forward (MediaFileOperationsWindowForwardSensorTests pins
    /// this file's two scopes).
    @discardableResult
    func startArchiveAngelByUser(count: Int, recordIDs: [UUID]?, makeLossless: Bool,
                                 model: VideoScanModel, bufferRoot: URL,
                                 policy: AngelRecommendationPolicy) -> ArchiveAngelJob {
        if let recordIDs {
            return self.startedByUser {
                $0.startArchiveAngel(recordIDs: recordIDs, makeLossless: makeLossless, model: model,
                                     bufferRoot: bufferRoot, policy: policy)
            }
        }
        return self.startedByUser {
            $0.startArchiveAngel(count: count, makeLossless: makeLossless, model: model,
                                 bufferRoot: bufferRoot, policy: policy)
        }
    }

    /// Angel Checks: the app's own initiative — deliberately NOT inside
    /// `startedByUser` (MediaFileOperationsWindowForwarderTests pins this
    /// file's two user-origin scopes; a background verify must not raise
    /// the window).
    func startVerifyAudioForAngel(record: VideoRecord, model: VideoScanModel) -> (any MediaFileOperationJob)? {
        startVerifyAudio(record: record, model: model)
    }

    /// Keep footage current: background origin, whole catalog.
    func startFindSimilarFootageForAngel(model: VideoScanModel) -> (any MediaFileOperationJob)? {
        let job = startFindSimilarFootage(scope: .catalog, model: model)
        return job.wasRefused ? nil : job
    }
}
