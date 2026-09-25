// AngelSeams.swift
// What the Archive Angel needs from the rest of the app, as protocols
// (docs/archive_angel_consolidation_plan.md, "Target architecture"). The
// façade (Facade/ArchiveAngel.swift) is composed from these; the app's
// conformances are ALL in Seams/AppConformances.swift, so the Angel's whole
// outbound surface can be read in two files.
//
// (For Rick: each protocol is an abstract base class with only pure virtual
// methods — `protocol` ≈ C++ interface; `AnyObject` restricts conformers to
// classes so the façade can hold them `weak`, like a non-owning pointer.)
//
// Most requirements are spelled exactly like the members the conformers
// already had, so the conformances add no behaviour — they declare it.
//
// S2 scope: the seams exist and the façade, the sweep wiring, the busy gate,
// navigation, prepare and the buffer root go through them. The core types
// (ArchiveAngelJob, ArchiveAngelPromoter, the projection) still take the
// concrete VideoScanModel / MediaFileOperationsCenter — that coupling is
// counted by ArchiveAngelBoundarySensorTests (COUPLING) and is S6's work.

import Foundation
import VideoScanCore

/// The catalog as the Angel sees it.
@MainActor
protocol AngelCatalog: AnyObject {
    /// O(1) (RecordIDIndex).
    func record(forID id: UUID) -> VideoRecord?
    /// O(1) (RecordPathIndex) — first record with exactly this fullPath,
    /// the same answer `records.first { $0.fullPath == path }` gave.
    func record(forPath path: String) -> VideoRecord?
    var isReadOnly: Bool { get }
    /// A scan or a Combine is running — the sweep parks.
    var isCatalogBusyForAngel: Bool { get }
    /// Scorer inputs for every active record (the sweep's snapshot).
    func archiveAngelSweepCandidates() -> [ArchiveAngelCandidate]
    /// The shared "is this archived?" predicate (never a private subset).
    func isArchivedOrVersionOfArchived(_ rec: VideoRecord) -> Bool
    /// LIVE: may this record be recommended right now? Not purged, set
    /// aside or superseded, and nothing Promote would refuse permanently
    /// (the 2026-09-16 "already promoted" guard). O(1) — index lookups.
    func isRecommendableNow(_ rec: VideoRecord) -> Bool
    /// The keeper policy, built once per pass by the caller.
    func duplicateKeeperPolicy() -> DuplicateKeeperPolicy
    /// When the person last touched the catalog UI (the preview sweep's
    /// interaction gate — the one every keystroke already pings). Angel
    /// Checks read bytes, so they wait for a longer quiet spell than the
    /// scoring sweep. nil = never.
    var lastUserInteractionAt: CFAbsoluteTime? { get }
    /// The person pressed something (an Angel row or strip button).
    func noteUserInteraction()
    /// Keep footage current (docs/archive_angel_wise_design.md §5): how
    /// many active records carry a footage group, and the newest run
    /// stamp among them. O(n), once per launch and rarely after.
    func footageCurrency() -> (grouped: Int, newestScan: Date?)
    /// Console + videoscan.log — a user-visible line.
    func angelLog(_ line: String)
    /// Retire the catalogued companions of batches a settle reclaimed
    /// (VideoScanModel+ArchiveAngelCompanions). Returns records retired.
    @discardableResult
    /// `presence`: positive absence only (codex #1714 R1).
    func forgetArchiveAngelCompanions(settled plans: [ArchiveAngelPlan],
                                      presence: (String) -> ArchiveAngelFilePresence) -> Int
    /// Launch pass over the buffer (VideoScanModel+ArchiveAngelCompanions).
    @discardableResult
    func reconcileArchiveAngelBufferAtLaunch(bufferRoot: URL,
                                             presence: @escaping @Sendable (String) -> ArchiveAngelFilePresence) async -> Int

    // Show Copies… (S4) — the copy-family walk (Review/ArchiveAngelShowCopies).

    /// Every active (not purged) record — O(n), once per Show Copies.
    func activeRecordsForCopyFamily() -> [VideoRecord]
    /// The Master Archive copy promoted from `record`, if any.
    func masterArchiveCopy(of record: VideoRecord) -> VideoRecord?
    /// The record an archive copy was promoted from, if any.
    func promotionSource(of record: VideoRecord) -> VideoRecord?
    /// Is `record` itself a copy inside the Master Archive?
    func isArchiveCopy(_ record: VideoRecord) -> Bool

    /// Balance Audio outputs already catalogued for `record` (active,
    /// `derivedFrom` = record, derivationKind "balanceAudio"). O(n) — once
    /// per prepared row. The prepare step reuses one instead of balancing
    /// again (S4 fix — the Helper's 2026-08-19 rule).
    func catalogedBalancedCopies(of record: VideoRecord) -> [VideoRecord]
    /// Save the catalog durably, AWAITED off the main actor (codex #1659 —
    /// never the synchronous quit-time save); true = on disk. The rollback
    /// journal is cleared only after this succeeds (codex #1654).
    func saveCatalogAcknowledged() async -> Bool
}

/// "Show in Catalog" from anywhere in the Angel.
@MainActor
protocol AngelNavigator: AnyObject {
    /// True iff `id` still resolves to a live record.
    func canNavigateToRecord(id: UUID) -> Bool
    /// Focus the catalog on one record (and its duplicate group), select it.
    func showInCatalog(recordID: UUID)
    /// Focus the catalog on a set of records under a label, nothing selected.
    func showInCatalog(focus ids: Set<UUID>, label: String)
}

/// The Media File Operations center: jobs the Angel starts or waits behind.
@MainActor
protocol AngelJobRunner: AnyObject {
    /// An Archive Angel or Promote job is active — the sweep parks.
    var isBusy: Bool { get }
    /// Any Media File Operations job is active (Angel Checks park).
    var hasActiveJobs: Bool { get }
    /// Start a batch the USER asked for (claims user origin, so the MFO
    /// window comes forward). `recordIDs` nil = the Angel picks `count`.
    @discardableResult
    func startArchiveAngelByUser(count: Int, recordIDs: [UUID]?, makeLossless: Bool,
                                 model: VideoScanModel, bufferRoot: URL,
                                 policy: AngelRecommendationPolicy) -> ArchiveAngelJob
    /// Angel Checks (docs/archive_angel_wise_design.md §4): the ordinary
    /// Verify Audio job for one record, started on the APP's initiative —
    /// no user origin, so the MFO window stays where it is. nil = refused
    /// (a verify job for this record is already running).
    func startVerifyAudioForAngel(record: VideoRecord, model: VideoScanModel) -> (any MediaFileOperationJob)?
    /// Keep footage current (§5): Find Similar Footage over the whole
    /// catalog, background origin. The verb queues behind a run in
    /// progress (never refused); nil only when the center could not add it.
    func startFindSimilarFootageForAngel(model: VideoScanModel) -> (any MediaFileOperationJob)?
}

/// The Master Archive: where Promote puts things.
@MainActor
protocol AngelArchive: AnyObject {
    var masterArchiveRootPath: String? { get }
    func buildPromotePlan(recordIDs ids: [UUID]) -> ArchivePromotePlan?
}

/// The Media Ledger: the attention memory's source of truth.
@MainActor
protocol AngelLedger: AnyObject {
    var mediaLedger: MediaLedger { get }
    @discardableResult
    func ledgerAngelAttention(_ kind: MediaLedgerEvent.Kind, recordIDs: [UUID],
                              batchID: String?, reason: String?,
                              scores: [UUID: Int], at: Date) -> Task<Void, Never>?
    /// dateSet / placeSet lines (S4: an inherited fact that landed with
    /// its promote is ledgered by the angel).
    @discardableResult
    func noteUserDateEdited(_ rec: VideoRecord, by: MediaLedgerEvent.Actor) -> Task<Void, Never>?
    @discardableResult
    func noteUserPlaceEdited(_ rec: VideoRecord, by: MediaLedgerEvent.Actor) -> Task<Void, Never>?
}
