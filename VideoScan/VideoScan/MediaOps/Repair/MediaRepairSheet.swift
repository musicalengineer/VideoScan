import AppKit
import SwiftUI

// MARK: - "Repair…" — the one door (Rick 2026-10-08)
//
// "Make a fixed copy of this damaged file next to it, and show me what
// changed."
//
// Top to bottom: the ORANGE "Recommended action" banner (what Verify
// found, the fix in one line); the plan — one checkbox per fix, ticked at
// the app's recommendation, changeable; what happens to picture and sound
// (copied or re-encoded, the expected change); where the copy goes (beside
// the original, or — when the original's drive is protected — a folder
// the person chooses, never a protected one); then the GREEN "Repair Now".
// While it runs and after, the sheet shows the job's progress and the
// before → after card. The same job is in the operations window.
//
// Presented with `.sheet(item:)`. Nothing here writes a file; the job does.

struct MediaRepairSheetRequest: Identifiable {
    let id = UUID()
    let record: VideoRecord
    /// This session's sound diagnosis (Verify full tier / Verify Audio).
    let audioDiagnosis: AudioVerifyDiagnosis?
    /// Hand off to Verify… (after this sheet starts dismissing).
    let onVerify: () -> Void
    /// Select a row in the catalog (after Link Repaired Copy…).
    var onSelectRecord: (UUID) -> Void = { _ in }
}

struct MediaRepairSheet: View {
    @EnvironmentObject private var fileOpsCenter: MediaFileOperationsCenter
    @EnvironmentObject private var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let request: MediaRepairSheetRequest

    @State private var selection: MediaRepairSelection
    @State private var picture: PictureLoad = .notNeeded
    @State private var chosenFolder: URL?
    @State private var folderRefusal: String?
    @State private var job: MediaRepairJob?

    enum PictureLoad: Equatable {
        case notNeeded, loading
        case ready(MediaRepairPicturePlan)
        case refused(String)
    }

    init(request: MediaRepairSheetRequest) {
        self.request = request
        _selection = State(initialValue: MediaRepairSelection(offers: Self.offers(for: request)))
    }

    private var record: VideoRecord { request.record }
    private var card: MediaReportCard? {
        record.mediaReportCard.flatMap { $0.isCurrent(forSizeBytes: record.sizeBytes) ? $0 : nil }
    }
    private var balance: MediaRepairBalanceInput? { MediaRepairBalanceInput(diagnosis: request.audioDiagnosis) }
    private var recipe: MediaRepairRecipe { selection.recipe(balance: balance) }

    /// Every fix: the card's earned ones first (ticked), then "More
    /// repairs", each available or not with the reason.
    static func offers(for request: MediaRepairSheetRequest) -> [MediaRepairOffer] {
        let r = request.record
        let card = r.mediaReportCard.flatMap { $0.isCurrent(forSizeBytes: r.sizeBytes) ? $0 : nil }
        return MediaRepairPlan.allOffers(for: card, sound: MediaRepairSoundFacts(diagnosis: request.audioDiagnosis),
                                         hasPicture: r.streamType == .videoAndAudio || r.streamType == .videoOnly,
                                         hasSound: r.streamType == .videoAndAudio || r.streamType == .audioOnly)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Repair").font(.title2.weight(.semibold)).accessibilityIdentifier("repair.title")
            Text(record.filename).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let job {
                        MediaRepairRunningView(job: job)
                    } else {
                        planBody
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 280, maxHeight: 520)
            buttons
        }
        .padding(24)
        .frame(width: 640)
        .task(id: recipe.picture == .removeRepeatedFrames) { await loadPicturePlan() }
    }

    // MARK: Plan

    @ViewBuilder
    private var planBody: some View {
        if let card {
            MediaRepairBanner(advice: MediaRepairAdvice.advice(for: card, offers: selection.offers,
                                                              balance: balance, sourceName: record.filename))
        } else {
            Label("Not verified yet. Verify the file first and Repair will recommend what to fix — or re-wrap it losslessly below.",
                  systemImage: "info.circle")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        GroupBox("What Repair will do") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(selection.offers.filter { $0.answers != nil }) { offer in fixRow(offer) }
                if selection.offers.allSatisfy({ $0.answers == nil }) {
                    Text("Nothing is ticked yet — Verify recommends what this file needs.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                DisclosureGroup("More repairs") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(selection.offers.filter { $0.answers == nil }) { offer in fixRow(offer) }
                    }
                    .padding(.top, 6)
                }
                .font(.callout)
                .accessibilityIdentifier("repair.moreRepairs")
                Text(selection.isRecommendation ? "Ticked: VideoScan's recommendation." : "You changed the recommendation.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        streamsBox
        destinationBox
        MediaRepairLifecycleSection(record: record, onSelectRecord: request.onSelectRecord)
        DisclosureGroup("The same steps by hand (for reference)") {
            ForEach(MediaRepairAdvice.manualSteps(recipe, sourceName: record.filename), id: \.self) { step in
                Text(step).font(.callout.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }

    private func fixRow(_ offer: MediaRepairOffer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(offer.fix.title, isOn: Binding(get: { selection.isOn(offer.fix) },
                                                  set: { selection.set(offer.fix, on: $0) }))
                .disabled(!offer.isAvailable || pictureRefusal(for: offer.fix) != nil)
                .accessibilityIdentifier("repair.fix.\(offer.fix.rawValue)")
            Text(pictureRefusal(for: offer.fix) ?? offer.unavailableReason ?? offer.fix.explanation)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
    }

    private func pictureRefusal(for fix: MediaRepairFix) -> String? {
        guard fix == .removeRepeatedFrames, case .refused(let why) = picture else { return nil }
        return why
    }

    private var streamsBox: some View {
        let plan: MediaRepairPicturePlan? = { if case .ready(let p) = picture { return p }; return nil }()
        let lines = MediaRepairSelection.streamLines(recipe, picture: plan)
            + recipe.skipped.map { "Not in this pass — \($0.fix.title): \($0.reason)." }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(lines, id: \.self) { Text($0).font(.callout).fixedSize(horizontal: false, vertical: true) }
        }
    }

    // MARK: Destination

    private var outputName: String {
        MediaRepairOutput.fileName(sourcePath: record.fullPath, recipe: recipe, audioCodec: record.audioCodec)
    }

    private var destination: MediaRepairOutput.Destination {
        MediaRepairOutput.destination(sourcePath: record.fullPath, fileName: outputName,
                                      protectionNote: protectionNote(record.fullPath),
                                      workspace: MediaRepairOutput.defaultWorkspace)
    }

    private func protectionNote(_ path: String) -> String? {
        let label = model.archiveVolumeProtection()?.label ?? "the archive volume"
        return model.bulkDeleteRefusal(forPath: path).map { VideoScanModel.bulkDeleteRefusalNote($0, volume: label) }
    }

    /// The one file this run will create; nil = a folder must be chosen.
    private var outputURL: URL? {
        switch destination {
        case .beside(let url): return url
        case .ask: return chosenFolder?.appendingPathComponent(outputName)
        }
    }

    @ViewBuilder
    private var destinationBox: some View {
        switch destination {
        case .beside(let url):
            Text("The repaired copy will be saved as \(url.lastPathComponent), beside the original. The original is never changed.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        case .ask(_, _, let why):
            VStack(alignment: .leading, spacing: 6) {
                Text(why).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Choose Folder\u{2026}") { chooseFolder() }
                        .accessibilityIdentifier("repair.chooseFolder")
                    if let url = outputURL { Text(url.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle) }
                }
                if let folderRefusal { Text(folderRefusal).font(.callout).foregroundStyle(.red) }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = chosenFolder ?? MediaRepairOutput.defaultWorkspace
        panel.prompt = "Save Here"
        panel.message = "Choose where to save the repaired copy of \(record.filename)"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let candidate = folder.appendingPathComponent(outputName)
        folderRefusal = MediaRepairOutput.refusal(forChosen: candidate, sourcePath: record.fullPath,
                                                  isProtected: { protectionNote($0) })
            ?? (MediaRepairEngine.isFamilyArchivePath(candidate.path) ? "That drive is the family archive — choose a folder on another drive." : nil)
        chosenFolder = folderRefusal == nil ? folder : nil
    }

    // MARK: Buttons

    private var canRun: Bool {
        guard job == nil, !recipe.isEmpty, outputURL != nil else { return false }
        if recipe.picture == .removeRepeatedFrames, case .ready = picture { return true }
        return recipe.picture != .removeRepeatedFrames
    }

    private var buttons: some View {
        HStack {
            if job == nil {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                if card == nil {
                    Button(CatalogRowMenuText.verify(count: 1)) {
                        VerifyAudioDismissHandoff.perform(dismiss: { dismiss() }, action: request.onVerify)
                    }
                    .accessibilityIdentifier("repair.verifyFirst")
                }
            }
            Spacer()
            if job != nil {
                Button("Show Operations") { MediaFileOperationsWindowOpener.openBehindMain(openWindow) }
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Repair Now") { start() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRun)
                    .accessibilityIdentifier("repair.repairNow")
            }
        }
        .controlSize(.large)
    }

    private func start() {
        guard let output = outputURL else { return }
        let besideOriginal: Bool = { if case .beside = destination { return true }; return false }()
        let fixes = Array(selection.chosen)
        _ = model.noteMissingFileForUserAction(record)
        job = fileOpsCenter.startedByUser { center in
            center.startRepair(record: record, fixes: fixes, output: output,
                               besideOriginal: besideOriginal, model: model)
        }
        MediaFileOperationsWindowOpener.openBehindMain(openWindow)
    }

    // MARK: The picture plan (header only, off the main actor)

    private func loadPicturePlan() async {
        guard recipe.picture == .removeRepeatedFrames else { picture = .notNeeded; return }
        picture = .loading
        do {
            guard let facts = try await MediaRepairProbe.summary(path: record.fullPath, control: nil).picture else {
                picture = .refused("This file has no picture.")
                return
            }
            switch MediaRepairPicturePlan.justify(facts) {
            case .success(let plan): picture = .ready(plan)
            case .failure(let refusal): picture = .refused(refusal.reason)
            }
        } catch {
            picture = .refused("The picture couldn't be read (\(error.localizedDescription)).")
        }
    }
}

/// The sheet after Repair Now: the job's progress, then how it ended.
struct MediaRepairRunningView: View {
    @ObservedObject var job: MediaRepairJob

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if job.state.isActive {
                ProgressView(value: job.fraction)
                Text(job.subtitle).font(.callout).foregroundStyle(.secondary)
                Text("You can close this window — the repair keeps going in the operations window.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let comparison = job.comparison {
                MediaRepairComparisonView(comparison: comparison)
                revealButton
            } else {
                Label(job.subtitle, systemImage: Self.icon(job.state))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                revealButton
            }
        }
        .accessibilityIdentifier("repair.running")
    }

    @ViewBuilder
    private var revealButton: some View {
        if case .repaired(let url, _)? = job.outcome {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    static func icon(_ state: MediaFileOperationState) -> String {
        switch state {
        case .finished: return "checkmark.circle"
        case .cancelled: return "stop.circle"
        default: return "exclamationmark.triangle"
        }
    }
}

/// The repair lifecycle, behind the same door (Rick 2026-10-08): link a
/// copy repaired with another tool, or confirm a repaired copy that sounds
/// right. Same model calls the row menu used; nothing new is decided here.
struct MediaRepairLifecycleSection: View {
    @EnvironmentObject private var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    let record: VideoRecord
    let onSelectRecord: (UUID) -> Void

    /// Link Repaired Copy… — for a file whose sound Verify called damaged
    /// (the menu item's old condition), not itself a repaired copy.
    private var canLink: Bool {
        record.derivedFrom == nil && !CatalogRowMenuRules.damagedAudio([record]).isEmpty
    }

    /// Confirm — this file IS a repaired copy awaiting "Sounds Good".
    private var canConfirm: Bool {
        record.isAwaitingConfirmation && record.derivedFrom.flatMap { model.record(forID: $0) } != nil
    }

    var body: some View {
        if canLink || canConfirm {
            GroupBox("Repaired copies") {
                VStack(alignment: .leading, spacing: 8) {
                    if canConfirm {
                        Button(CatalogRowMenuText.confirmRepairs(count: 1)) {
                            _ = model.confirmRepairs(repairIDs: [record.id])
                            dismiss()
                        }
                        .accessibilityIdentifier("catalog.row.confirmRepair")
                        Text("You've listened and it sounds right: keep this repaired copy as the one to use. The original is hidden from the everyday view — never deleted — and your tags, notes, people and ratings carry over.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if canLink {
                        Button("Link Repaired Copy\u{2026}") { link() }
                            .accessibilityIdentifier("catalog.row.linkRepairedCopy")
                        Text("Already repaired this file with another tool? Pick that file and it joins the catalog as this one's repaired copy — then confirm it when it sounds right.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    /// Pick the externally repaired file and adopt it (GH #132 P4 — the
    /// handler that lived in the row menu, unchanged). Failures alert
    /// with the model's message and change nothing.
    private func link() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the repaired copy of \(record.filename)"
        panel.prompt = "Link Repaired Copy"
        panel.directoryURL = URL(fileURLWithPath: record.directory, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let originalID = record.id
        Task { @MainActor in
            do {
                let newRec = try await model.adoptExternalRepair(originalID: originalID, fileURL: url)
                onSelectRecord(newRec.id)
                dismiss()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't Link the Repaired Copy"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
}
