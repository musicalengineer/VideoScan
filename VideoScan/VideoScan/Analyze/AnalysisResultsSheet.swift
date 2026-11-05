// AnalysisResultsSheet.swift — Content Analysis ▸ Results… (Rick 2026-11-04,
// BACKLOG "results sheet"; background_service.md §6 view 1): a read-only
// view of what VideoScan Background's analyzers produced. Per analyzer: the
// counts by outcome (era found · no usable era · given up after 3 tries ·
// tries in progress · still to do), "agrees with your confirmed date within
// 5 years", the pace and a plain ETA; and the files of the selected outcome
// in a Table — double-click (or Show in Catalog) selects the file in the
// Catalog through the existing door; Show Dossier opens the file dossier view
// (docs/design/file_dossier_view.md, through its one door) over the sheet.
//
// Plain and conventional on purpose (Rick owns the look): an outcome list on
// the left, a Table on the right, Refresh and Done at the bottom.
//
// NO O(records) work in this body: every number and row comes from the
// store's published report and list (built off the main actor by Core's
// AnalysisResultsReport); the Table is lazy over at most 10,000 rows.
// AnalysisResultsSheetSensorTests pins it.
//
// (For Rick: `@StateObject` ≈ the view owns the controller's lifetime, like a
// std::unique_ptr member created once per sheet.)

import SwiftUI
import VideoScanCore

struct AnalysisResultsSheet: View {

    @StateObject private var store: AnalysisResultsStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: AnalysisResultsReport.FileRow.ID?
    /// The row whose file dossier is open (Show Dossier).
    @State private var dossierRow: AnalysisResultsReport.FileRow?

    init(store: @autoclosure @escaping () -> AnalysisResultsStore) {
        _store = StateObject(wrappedValue: store())
    }

    static let title = "Content Analysis Results"
    static let subtitle = "What VideoScan Background's analyzers produced. Read-only: nothing here changes the catalog. "
        + "A machine era is never a date; your date always wins."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let failure = store.failure {
                Text("The results could not be read: \(failure)")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let analyzer = store.analyzer {
                HStack(alignment: .top, spacing: 16) {
                    summary(analyzer)
                        .frame(width: 300)
                    fileList
                }
            } else {
                ProgressView("Reading the catalog…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 960, minHeight: 600)
        .task { await store.load() }
        .onDisappear { store.cancel() }
        .accessibilityIdentifier("analysisResults.sheet")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title).font(.title2.weight(.semibold))
                Text(Self.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let report = store.report, report.analyzers.count > 1 {
                Picker("Analyzer", selection: Binding(
                    get: { store.analyzer?.signer ?? "" },
                    set: { signer in Task { await store.select(signer: signer) } })) {
                    ForEach(report.analyzers) { a in
                        Text(Self.analyzerName(a)).tag(a.signer)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 360)
                .accessibilityIdentifier("analysisResults.analyzer")
            }
        }
    }

    /// "Machine era · 8B (the one the helper runs)" — the signer is in the help.
    static func analyzerName(_ a: AnalysisResultsReport.Analyzer) -> String {
        (a.signer.contains("/era-") ? "Machine era" : "Analyzer") + " · \(a.modelShortName)"
            + (a.isSeated ? " (the one the helper runs)" : "")
    }

    // MARK: Summary (left)

    private func summary(_ a: AnalysisResultsReport.Analyzer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.analyzerName(a)).font(.headline).help(a.signer)
            List(selection: Binding(
                get: { store.outcome },
                set: { new in if let new { Task { await store.select(outcome: new) } } })) {
                ForEach(AnalysisResultsReport.Outcome.allCases) { outcome in
                    HStack {
                        Text(outcome.title)
                        Spacer()
                        Text(store.report?.countWords(a, outcome) ?? "")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .tag(outcome)
                    .help(Self.outcomeHelp(outcome))
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(height: 150)
            .accessibilityIdentifier("analysisResults.outcomes")

            VStack(alignment: .leading, spacing: 6) {
                fact("Agrees with your confirmed date within 5 years", AnalysisResultsReport.agreementWords(a.agreement),
                     help: "Files with your date and an era from this analyzer whose era's middle year is within 5 years of "
                        + "your year and whose range is at most 10 years wide — the same closeness rule as Catalog Status.")
                fact("Pace", AnalysisResultsReport.rateWords(a.rate),
                     help: "Files that got their first answer from this analyzer in the last hour and the last 24 hours.")
                fact("Still to do", AnalysisResultsReport.etaWords(stillToDo: a.stillToDo, rate: a.rate),
                     help: "Video files in the catalog this analyzer has not answered yet (answers waiting in the journal count as answered), "
                        + "including files on drives that are not connected.")
                if a.other > 0 {
                    fact("Other answers", "\(a.other.formatted()) file\(a.other == 1 ? "" : "s") with an answer that is none of the above",
                         help: "For example a date read off the screen but no era.")
                }
                if let problem = store.report?.triesProblem {
                    fact("Tries in progress unavailable", problem)
                }
                if let journal = store.journalWords { fact("Journal", journal) }
            }
            Spacer(minLength: 0)
        }
    }

    private func fact(_ label: String, _ value: String, help: String = "") -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .help(help)
    }

    static func outcomeHelp(_ outcome: AnalysisResultsReport.Outcome) -> String {
        switch outcome {
        case .eraFound: return "The analyzer gave an era from the pictures alone. It is not a date and files nothing. "
            + "Includes files whose every copy has since been removed from the catalog (shown greyed)."
        case .eraNone: return "The analyzer looked at the whole file and found no usable era. Not a failure; it will not look again."
        case .gaveUp: return "Three tries ended with no answer (frames that would not decode, a model that never answered). The reason is the last try's."
        case .inProgress: return "Files tried at least once with no answer yet; after the third try the analyzer gives up and says why."
        case .stillToDo: return "Video files this analyzer has not answered yet."
        }
    }

    // MARK: Files (right)

    private var rows: [AnalysisResultsReport.FileRow] { store.files?.rows ?? [] }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Table(rows, selection: $selection) {
                TableColumn("Name") { row in
                    Text(row.filename).foregroundStyle(row.removed ? .secondary : .primary)
                }
                .width(min: 140, ideal: 220)
                TableColumn("Value", value: \.value)
                    .width(min: 120, ideal: 180)
                TableColumn("Reason") { row in Text(row.reason).help(row.reason) }
                    .width(min: 160, ideal: 280)
                TableColumn("Path") { row in Text(row.path).help(row.path).foregroundStyle(.secondary) }
                    .width(min: 160, ideal: 300)
            }
            .contextMenu(forSelectionType: AnalysisResultsReport.FileRow.ID.self) { ids in
                Button("Show in Catalog") { show(ids.first) }.disabled(ids.count != 1)
                if store.dossiers != nil {
                    Button("Show Dossier") { showDossier(ids.first) }.disabled(ids.count != 1)
                }
            } primaryAction: { ids in
                show(ids.first)
            }
            .overlay {
                if store.filesLoading {
                    ProgressView()
                } else if let failure = store.filesFailure {
                    Text("This list could not be read: \(failure)").foregroundStyle(.secondary).padding()
                } else if store.files != nil, rows.isEmpty {
                    Text("No files").foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("analysisResults.files")
            HStack {
                if let files = store.files, files.truncated {
                    Text("Showing the first \(files.rows.count.formatted()) by name.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let problem = store.revealProblem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.dossiers != nil {
                    Button("Show Dossier") { showDossier(selection) }
                        .disabled(selection == nil)
                        .help("Everything the catalog knows about this file: technical facts, patterns and events.")
                        .accessibilityIdentifier("analysisResults.showDossier")
                }
                Button("Show in Catalog") { show(selection) }
                    .disabled(selection == nil)
                    .accessibilityIdentifier("analysisResults.showInCatalog")
            }
        }
        .sheet(item: $dossierRow) { row in
            if let loader = store.dossiers {
                FileDossierSheet(row: row, loader: loader, onShowInCatalog: { store.reveal(row) })
            }
        }
    }

    private func showDossier(_ id: AnalysisResultsReport.FileRow.ID?) {
        guard let id, let row = store.files?.rows.first(where: { $0.id == id }) else { return }
        dossierRow = row
    }

    private func show(_ id: AnalysisResultsReport.FileRow.ID?) {
        guard let id, let row = store.files?.rows.first(where: { $0.id == id }) else { return }
        store.reveal(row)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if let report = store.report {
                Text("As of \(Date(timeIntervalSince1970: TimeInterval(report.builtAt)).formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") { Task { await store.load() } }
                .disabled(store.loading)
                .accessibilityIdentifier("analysisResults.refresh")
            Button("Done") { store.cancel(); dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }
}

/// The Results sheet's file dossier, over the sheet: the file's name, the
/// three groups, Show in Catalog and Done (the design's mock, §3).
struct FileDossierSheet: View {
    let row: AnalysisResultsReport.FileRow
    let loader: FileDossierLoader
    let onShowInCatalog: () -> Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.filename).font(.headline).textSelection(.enabled)
                    Text(row.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(row.path)
                }
                Spacer()
                // Closes either way: when the file cannot be shown, the Results sheet
                // says why under its list.
                Button("Show in Catalog") { _ = onShowInCatalog(); dismiss() }
            }
            ScrollView {
                FileDossierView(fileID: row.recordID, loader: loader)
                    .padding(.trailing, 8)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 420, idealHeight: 560)
        .accessibilityIdentifier("analysisResults.dossierSheet")
    }
}
