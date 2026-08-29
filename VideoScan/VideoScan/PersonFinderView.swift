// PersonFinderView.swift
// Multi-volume person-finding UI — jobs list, progress bars, results, console.
//
// The view's body sections were extracted verbatim into per-area
// extension files (refactor 2026-06-24); this file now holds the struct's
// stored state, the small shared computed properties, `body`, and the
// section-header helper:
//   • PersonFinderView+People.swift   — People gallery + undo banner
//   • PersonFinderView+Faces.swift    — loaded-faces strip + face popover
//   • PersonFinderView+Jobs.swift     — search-header buttons + jobs list
//   • PersonFinderView+Results.swift  — results table + inspector
//   • PersonFinderView+Helpers.swift  — browse panels + recent paths
// Several members lost their `private` keyword so the cross-file
// extensions can reach them — a Swift `private` member is file-private,
// invisible to extensions declared in other files (single-module app, so
// internal is the same visibility in practice). Each relaxation is noted
// inline below.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os.log

// Relaxed from `private` to internal (file-scope) so the cross-file
// extension PersonFinderView+Results.swift (playInQuickTime) can log
// through the same Logger — a `private` file-scope binding isn't visible
// to other files in the same module. (refactor 2026-06-24)
let pfViewLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "personfinder.view")

// MARK: - Main View

struct PersonFinderView: View {
    // NOTE: Don't subscribe to DashboardState here. Earlier this view had
    // `@EnvironmentObject var dashboard: DashboardState` but never read
    // `dashboard.*` in its body — only used it once in onAppear to wire
    // `model.dashboard = dashboard`. Each of DashboardState's 51 @Published
    // properties (visionFPS, visionMsPerFrame, visionWorkers, etc.) gets
    // written multiple times per second during scans, retriggering this
    // view's body and cascading through every ScanJobRow. The Matt-scan
    // sample showed PersonFinderView.body 166× in 30s as the dominant
    // SwiftUI hot path. Wiring is now done in ContentView, which already
    // observes the model that owns the dashboard reference.
    @EnvironmentObject var model: PersonFinderModel
    // Used in PersonFinderView+Results.swift (isInCatalog / showInCatalog)
    // and forwarded in PersonFinderView+People.swift — the file-scoped
    // env-object lint can't see across the extension split. Subscription
    // is intentional. See project_bug_prevention_strategy memory.
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject var catalogModel: VideoScanModel
    // selectedTab / ftHighlight relaxed from `private` — read by the People
    // and Results extensions (Family Tree jump, Show-in-Catalog). (2026-06-24)
    @AppStorage("selectedTab") var selectedTab: Int = 0
    @AppStorage("ftHighlightedPersonName") var ftHighlight: String = ""

    // The result-table/inspector state below was relaxed from `private` —
    // it's driven by the Results extension (PersonFinderView+Results.swift).
    // (2026-06-24)
    @State var selectedResultIDs = Set<UUID>()
    @State var inspectorShown = false
    @State var inspectorStreamInfo: StreamInspectInfo?
    @State var inspectorLoading = false
    @State var resultSortOrder = [KeyPathComparator(\ClipResult.videoFilename)]
    @State var resultTableData: [ClipResult] = []
    @AppStorage("resultsTableCollapsed") private var resultsCollapsed = false
    @AppStorage("peoplePaneCollapsed") private var peopleCollapsed = false
    @AppStorage("searchesPaneCollapsed") private var searchesCollapsed = false
    // showAllSearchHistory relaxed from `private` — toggled by the Jobs
    // extension's history affordance (PersonFinderView+Jobs.swift). (2026-06-24)
    @AppStorage("showAllSearchHistory") var showAllSearchHistory = false

    /// How many terminal (done/paused/cancelled) jobs to show before
    /// collapsing the rest behind a "Show more" affordance. Rick:
    /// "Display the last 5 searches with an options to show more history."
    /// Relaxed from `private` — read by the Jobs extension. (2026-06-24)
    static let visibleHistoryDefault = 5

    var selectedJobID: UUID? {
        get { model.selectedJobID }
        nonmutating set { model.selectedJobID = newValue }
    }
    var expandedJobIDs: Set<UUID> {
        get { model.expandedJobIDs }
        nonmutating set { model.expandedJobIDs = newValue }
    }
    var selectedJob: ScanJob? { model.jobs.first { $0.id == selectedJobID } }
    var hasAnyResults: Bool { model.jobs.contains { !$0.results.isEmpty } }

    // MARK: People Gallery — saved family profiles
    // (UI lives in PersonFinderView+People.swift; stored state stays here.)

    // confirmDeleteProfile / editingProfile / confirmTarget /
    // confirmationsTarget / editingOriginalName / justSavedProfileID /
    // scanLockMessage / draggingProfileID / peopleGalleryHeight relaxed
    // from `private` — all driven by the People extension. (2026-06-24)
    @State var confirmDeleteProfile: POIProfile?
    @State var editingProfile: POIProfile?
    /// Drives the Confirm-Person sheet. Set by the "Confirm…" context
    /// menu item on a PersonCard; the sheet presents the candidate
    /// labeling UI and clears this on dismiss. Rick 2026-06-16.
    @State var confirmTarget: ConfirmSheetTarget?
    /// Drives the View Confirmations sheet (cumulative progress).
    @State var confirmationsTarget: ConfirmationsTarget?
    /// The original name of the profile being edited (nil when adding new).
    @State var editingOriginalName: String?
    /// Briefly set after a profile save to flash confirmation on the card.
    @State var justSavedProfileID: String?
    /// Alert message shown when user tries to edit/switch during a scan.
    @State var scanLockMessage: String?
    /// Profile ID currently being dragged for reordering.
    @State var draggingProfileID: String?
    /// Drag-resizable height for the People gallery row. Default leans large
    /// so the family portraits read as the centerpiece — Rick wants the app
    /// to feel like it's about people first when he shows it off.
    @AppStorage("peopleGalleryHeight") var peopleGalleryHeight: Double = 180
    /// Watches output/person-eval-private/ for the newest blind holdout
    /// queue and drives the Review badge on the matching PersonCard.
    /// Refreshed when the gallery appears and when the review sheet
    /// closes (both in PersonFinderView+People.swift). Rick 2026-07-25.
    /// (`@StateObject` ≈ the view OWNS this heap object across renders,
    /// vs `@ObservedObject` which merely borrows one.)
    @StateObject var holdoutReview = HoldoutReviewCenter()
    /// Derived "Relationships" lines for the People cards (2026-08-27).
    /// Observed so cards refresh once the family tree finishes loading.
    @ObservedObject var kinshipCenter = KinshipDisplayCenter.shared
    /// Auto-derived profile → family-tree identity (2026-08-29): proposals,
    /// pins, and the tree tab's identity banner. Observed so a pin written
    /// here refreshes the gallery (pinsRevision).
    @ObservedObject var identityCenter = TreeIdentityCenter.shared
    /// The which-one sheet behind "Show in Family Tree" (item-binding form).
    @State var identityPickTarget: TreeIdentityPickTarget?
    /// When enabled, the People gallery shows every profile whose current
    /// tree-link reducer verdict is not `.pinned`. Session-scoped on purpose:
    /// a filter that survived relaunch would hide people silently.
    @State var showMissingGEDCOM = false
    /// Exact-record hint for the Family Tree tab (same key FamilyTreeDemoView
    /// reads); set alongside `ftHighlight` when the profile is pinned.
    @AppStorage("ftHighlightedPersonID") var ftHighlightID: String = ""
    /// One-photo-per-person memo for the gallery cards (2026-08-29).
    @ObservedObject var photoCenter = PersonPhotoCenter.shared

    // MARK: Loaded Faces Strip — compact scan-readiness indicator
    // (UI lives in PersonFinderView+Faces.swift; stored state stays here.)

    // showFailures / facesStripHeight / referencePaneCollapsed /
    // inspectedFace relaxed from `private` — driven by the Faces
    // extension. (2026-06-24)
    @State var showFailures = false
    @AppStorage("facesStripHeight") var facesStripHeight: Double = 90
    /// User-toggleable hide for the reference photo grid: keep the header
    /// (so you can still see who's loaded) but free up vertical space for
    /// the People gallery above. Persisted across launches.
    @AppStorage("referencePaneCollapsed") var referencePaneCollapsed: Bool = false
    @State var inspectedFace: ReferenceFace?

    var body: some View {
        VStack(spacing: 0) {
            // Section 1: People
            sectionHeader("People", icon: "person.2.fill",
                          collapsed: $peopleCollapsed,
                          badge: model.savedProfiles.isEmpty ? nil : "\(model.savedProfiles.count)")
            if !peopleCollapsed {
                peopleGallery
                Divider()
                loadedFacesStrip
            }
            Divider()

            // Section 2: Searches
            sectionHeader("Searches", icon: "magnifyingglass",
                          collapsed: $searchesCollapsed,
                          badge: model.jobs.isEmpty ? nil : "\(model.jobs.count)") {
                searchHeaderButtons
            }
            if !searchesCollapsed {
                jobsSection
                    .frame(minHeight: 90, maxHeight: resultsCollapsed ? .infinity : 300)
            }
            Divider()

            // Section 3: Results
            sectionHeader("Results", icon: "list.bullet",
                          collapsed: $resultsCollapsed,
                          badge: resultTableData.isEmpty ? nil : "\(resultTableData.count)")
            if !resultsCollapsed {
                resultsTable
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(minWidth: 960, maxHeight: .infinity, alignment: .top)
    }

    private func sectionHeader(_ title: String, icon: String,
                               collapsed: Binding<Bool>,
                               badge: String? = nil,
                               @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { collapsed.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 14)
                    Image(systemName: icon)
                        .font(.system(size: 13))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if let badge {
                        Text(badge)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.7))
    }
}
