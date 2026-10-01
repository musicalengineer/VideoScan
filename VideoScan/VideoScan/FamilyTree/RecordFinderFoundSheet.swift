// RecordFinderFoundSheet.swift
// GH #230 Phase A — "I found a record for <name>…": the sheet Rick fills in
// after downloading a record from one of the Record Finder links. Drop (or
// choose) the PDF/PNG/JPG, say where it came from and what it says, and —
// once he has read it — tick "I've read it and it is <name>" so Hallie is
// told (confirmed). The work is done by `RecordFinderFiler` off the main
// actor; this view only collects values and shows the named outcome.
//
// Nothing here reads the store in `body`. The site list is the person's
// own Record Finder links, computed once when the sheet was opened.
//
// C++ readers: `@State` ≈ a member the view owns that survives redraws;
// `$x` ≈ passing a reference to it into a control; `Task.detached` ≈
// starting a worker thread and awaiting its result.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VideoScanCore

/// What the sheet is for. `Identifiable` for `.sheet(item:)`.
struct RecordFinderFoundTarget: Identifiable {
    /// The tree person id.
    let id: String
    let subject: ResearchSubject
    let assetPerson: FamilyAssetPerson
    /// The person's Record Finder links (site picker choices).
    let links: [FamilyTreeResearchLinks.Link]
}

struct RecordFinderFoundSheet: View {
    let target: RecordFinderFoundTarget
    let speakerName: String
    let record: (@Sendable (CyberBrainWriter.Testimony) throws -> CyberBrainWriter.Receipt)?
    let onFiled: (RecordFilingOutcome) -> Void
    let onCancel: () -> Void

    private static let otherSite = "__other__"

    @State private var fileURL: URL?
    @State private var isDropTargeted = false
    @State private var siteChoice = RecordFinderFoundSheet.otherSite
    @State private var otherSiteTitle = ""
    @State private var recordType: FoundRecordType = .birth
    @State private var year = ""
    @State private var district = ""
    @State private var recordID = ""
    @State private var pageURL = ""
    @State private var transcription = ""
    @State private var confirmedRead = false
    @State private var isFiling = false
    @State private var outcomeText: String?
    @State private var outcomeIsProblem = false

    private var siteLinks: [FamilyTreeResearchLinks.Link] {
        target.links.filter { $0.siteID != nil }
    }

    private var siteTitle: String {
        if siteChoice == Self.otherSite { return otherSiteTitle }
        return siteLinks.first { $0.siteID == siteChoice }?.title ?? otherSiteTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("I found a record for \(target.subject.name)")
                .font(.system(size: 15, weight: .semibold))

            dropZone

            Form {
                Picker("Found on", selection: $siteChoice) {
                    ForEach(siteLinks) { link in
                        Text(link.title).tag(link.siteID ?? link.id)
                    }
                    Text("Another site…").tag(Self.otherSite)
                }
                .onChange(of: siteChoice) { _, new in recordType = Self.defaultType(forSite: new) }
                if siteChoice == Self.otherSite {
                    TextField("Site name", text: $otherSiteTitle)
                }
                Picker("Record", selection: $recordType) {
                    ForEach(FoundRecordType.allCases, id: \.self) { type in
                        Text(type.label).tag(type)
                    }
                }
                TextField("Year", text: $year)
                TextField("District, parish or DED", text: $district)
                TextField("The site's record number", text: $recordID)
                TextField("Record page address (https://…)", text: $pageURL)
            }
            .formStyle(.grouped)
            .frame(minHeight: 260)

            Text("What it says (Hallie repeats only this)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $transcription)
                .font(.system(size: 12))
                .frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))

            Toggle("I've read this record and it is \(target.subject.name) — tell Hallie (confirmed)",
                   isOn: $confirmedRead)
                .font(.system(size: 12))

            if let outcomeText {
                Text(outcomeText)
                    .font(.system(size: 11))
                    .foregroundStyle(outcomeIsProblem ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("The file is kept beside \(target.subject.name)'s photos (People/…/Documents). "
                 + "Your GEDCOM is never changed.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(isFiling ? "Filing…" : "File it") { file() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(fileURL == nil || isFiling)
                    .masterOnly()
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if let first = siteLinks.first?.siteID {
                siteChoice = first
                recordType = Self.defaultType(forSite: first)
            }
        }
    }

    private var dropZone: some View {
        HStack(spacing: 10) {
            Image(systemName: fileURL == nil ? "arrow.down.doc" : "doc.text.fill")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(fileURL?.lastPathComponent ?? "Drop the downloaded PDF, PNG or JPG here")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose file…") { chooseFile() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isDropTargeted ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06)))
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    fileURL = url
                    outcomeText = nil
                }
            }
            return true
        }
    }

    /// A sensible first guess from the site; Rick can change it.
    static func defaultType(forSite siteID: String) -> FoundRecordType {
        switch siteID {
        case let id where id.contains("census"): return .census
        case let id where id.contains("griffiths") || id.contains("tithe"): return .valuation
        case let id where id.hasPrefix("uk.tna") || id.contains("wo97") || id.contains("wo363"): return .military
        case let id where id.contains("wills") || id.contains("probate"): return .will
        case let id where id.contains("findagrave") || id.contains("graves") || id.contains("deceased"): return .burial
        case let id where id.contains("baptisms") || id.contains("registers"): return .baptism
        default: return .birth
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf, .png, .jpeg]
        panel.prompt = "Choose"
        panel.message = "Choose the record you downloaded for \(target.subject.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileURL = url
        outcomeText = nil
    }

    /// Off the main actor: only Sendable values cross into the task; the
    /// stores are built inside it from the archive configuration.
    private func file() {
        guard let fileURL else { return }
        isFiling = true
        outcomeText = nil
        let submission = FoundRecordSubmission(
            file: fileURL,
            siteID: siteChoice == Self.otherSite ? nil : siteChoice,
            siteTitle: siteTitle,
            recordType: recordType,
            year: year, district: district, recordID: recordID,
            pageURL: pageURL, transcription: transcription,
            confirmedRead: confirmedRead)
        let subject = target.subject
        let person = target.assetPerson
        let speaker = speakerName
        let record = self.record
        let configuration = FamilyAssetConfigurationCenter.shared.snapshot()
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> RecordFilingOutcome in
                let store = configuration.makeStore()
                let filer = RecordFinderFiler(
                    assetStore: store, assetPerson: person,
                    researchStore: ResearchStore(peopleRoot: store.peopleDirectory),
                    subject: subject, speakerName: speaker, record: record)
                return filer.file(submission)
            }.value
            isFiling = false
            if outcome.isSuccess {
                onFiled(outcome)
            } else {
                outcomeIsProblem = true
                outcomeText = outcome.message
                // A rollback or mixed state still changed files on disk;
                // let the inspector re-read.
                if case .refused = outcome {} else { onFiled(outcome) }
            }
        }
    }
}
