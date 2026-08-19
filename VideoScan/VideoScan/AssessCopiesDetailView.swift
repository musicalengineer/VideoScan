// AssessCopiesDetailView.swift
// The expanded row for an Assess Copies job in the Media File
// Operations window (Promote-Helper slice 2): verdict paragraph,
// cautions, one card per representation (role · signature · locations ·
// recommended instance · reason), and the action buttons that hand off
// to the EXISTING verbs — Promote (unchanged safe executor), Verify
// Audio, Transcode (companion / access copy).

import SwiftUI

struct AssessCopiesDetailView: View {
    @ObservedObject var job: AssessCopiesJob
    @EnvironmentObject var model: VideoScanModel
    @EnvironmentObject var center: MediaFileOperationsCenter

    @State private var transcodeRequest: TranscodeRequest?
    @State private var expandedReps: Set<String> = []
    /// Prepare-strip archive name for the ORIGINAL (Rick 2026-08-19):
    /// renames the copy ON THE WAY to the archive; master untouched. The
    /// Promote sheet shows the full vertical naming list (Original /
    /// Lossless edition / …) seeded from this + suggestions.
    @State private var archiveTitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let a = job.assessment {
                summary(a)
                if !a.cautions.isEmpty { cautions(a) }
                ForEach(a.representations) { rep in
                    representationCard(rep, assessment: a)
                }
                if a.recommendedInstanceID != nil {
                    prepareStrip(a)
                }
                actions(a)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Assessing…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 6))
        .sheet(item: $transcodeRequest) { request in
            TranscodeSheet(request: request)
                .environmentObject(center)
                .environmentObject(model)
        }
        .accessibilityIdentifier("assessCopies.detail")
    }

    // MARK: Summary / cautions

    private func summary(_ a: CopyFamilyAssessment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: a.recommendedRepresentation == nil ? "questionmark.circle.fill" : "crown.fill")
                .font(.title2)
                .foregroundStyle(a.recommendedRepresentation == nil ? Color.orange : Color.indigo)
            VStack(alignment: .leading, spacing: 3) {
                Text(a.headline).font(.headline)
                Text(a.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func cautions(_ a: CopyFamilyAssessment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(a.cautions, id: \.self) { c in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 11))
                        .padding(.top, 2)
                    Text(c)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Representation cards

    private func roleColor(_ r: CopyRole) -> Color {
        switch r {
        case .originalSource: return .indigo
        case .presumedOriginal: return .purple
        case .preservationCompanion: return .green
        case .editingDerivative: return .teal
        case .accessCopy: return .blue
        case .unconfirmedVariant: return .orange
        }
    }

    private func representationCard(_ rep: CopyRepresentation, assessment a: CopyFamilyAssessment) -> some View {
        let isRecommended = rep.id == a.recommendedRepresentationID
        let recInstance = rep.instances.first { $0.id == rep.recommendedInstanceID }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(rep.role.rawValue.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(roleColor(rep.role), in: Capsule())
                Text(rep.signature)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(rep.instances.count) location\(rep.instances.count == 1 ? "" : "s") · \(CatalogStorageTotals.displaySize(rep.sizeBytes))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button {
                    if expandedReps.contains(rep.id) { expandedReps.remove(rep.id) } else { expandedReps.insert(rep.id) }
                } label: {
                    Image(systemName: expandedReps.contains(rep.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Show every location of this representation")
            }
            Text(rep.reason)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let inst = recInstance {
                HStack(spacing: 6) {
                    Image(systemName: isRecommended ? "checkmark.seal.fill" : "arrow.turn.down.right")
                        .foregroundStyle(isRecommended ? Color.green : Color.secondary)
                        .font(.system(size: 11))
                    Text(isRecommended ? "Promote this copy:" : "Best copy:")
                        .font(.system(size: 11, weight: .medium))
                    Text(inst.fullPath)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(inst.fullPath)
                    if !inst.isReachable {
                        Text("offline").font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
            }
            if expandedReps.contains(rep.id) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rep.instances) { inst in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(inst.isReachable ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                            Text(inst.fullPath)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer()
                            if inst.isArchiveCopy {
                                Text("archive copy").font(.system(size: 10)).foregroundStyle(.indigo)
                            }
                            if inst.byteCluster == nil {
                                Text("no signature").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Text(CatalogStorageTotals.displaySize(inst.sizeBytes))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 8)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isRecommended ? Color.indigo.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isRecommended ? Color.indigo.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }

    // MARK: Actions

    private struct ActionContext {
        var rec: CopyRepresentation?
        var recID: UUID?
        var recRecord: VideoRecord?
        var companion: CopyRepresentation?
        var needsAudio: Bool
        var readOnly: Bool
        var recReachable: Bool { recRecord.map { VolumeReachability.isReachable(path: $0.fullPath) } ?? false }
    }

    private func actions(_ a: CopyFamilyAssessment) -> some View {
        let recID = a.recommendedInstanceID
        let ctx = ActionContext(rec: a.recommendedRepresentation,
                                recID: recID,
                                recRecord: recID.flatMap { job.record(for: $0) },
                                companion: a.representations.first { $0.role == .preservationCompanion },
                                needsAudio: a.actions.contains(.verifyAudioFirst),
                                readOnly: model.isReadOnly)
        return HStack(spacing: 8) {
            ForEach(a.actions, id: \.rawValue) { action in
                actionButton(action, ctx)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func actionButton(_ action: CopyFamilyAction, _ c: ActionContext) -> some View {
        switch action {
        case .verifyAudioFirst:
            Button {
                if let r = c.recRecord { _ = center.startVerifyAudio(record: r, model: model) }
            } label: { Label("Verify Audio First", systemImage: "waveform.badge.magnifyingglass") }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(c.recRecord == nil)
            .help("Run Verify Audio on the recommended copy before promoting it.")
        case .promoteRecommendedOriginal:
            Button {
                if let id = c.recID { promote([id]) }
            } label: { Label("Promote Recommended Original", systemImage: "archivebox.fill") }
            .disabled(c.recID == nil || c.readOnly)
            .help("Hands the recommended copy to Promote — verified byte-for-byte into the Master Archive; the original is never moved or changed.")
        case .chooseAnotherEquivalent:
            Menu {
                ForEach(c.rec?.instances ?? []) { inst in
                    Button(inst.fullPath) { promote([inst.id]) }
                        .disabled(!inst.isReachable || inst.isArchiveCopy)
                }
            } label: { Label("Choose Another Equivalent Copy…", systemImage: "list.bullet") }
            .help("Promote a different location of the same representation instead.")
        case .promoteOriginalAndCompanion:
            Button {
                var ids: [UUID] = []
                if let id = c.recID { ids.append(id) }
                if let cid = c.companion?.recommendedInstanceID { ids.append(cid) }
                promote(ids)
            } label: { Label("Promote Original + Companion", systemImage: "archivebox.fill") }
            .disabled(c.recID == nil || c.companion == nil || c.readOnly)
            .help("Promote the original and its lossless companion together.")
        case .createAndPromoteCompanion:
            Button {
                if let r = c.recRecord { transcodeRequest = TranscodeRequest(record: r, initialPreset: .preservation) }
            } label: { Label("Create Lossless Companion…", systemImage: "shield.lefthalf.filled") }
            .disabled(!c.recReachable)
            .help("Transcode the recommended original to a verified FFV1 preservation companion. Promote it afterwards (Assess again — it will show as a companion).")
        case .createAccessCopy:
            Button {
                if let r = c.recRecord { transcodeRequest = TranscodeRequest(record: r, initialPreset: .archival) }
            } label: { Label("Create Access Copy…", systemImage: "play.rectangle") }
            .disabled(!c.recReachable)
            .help("Make a compact HEVC viewing copy from the recommended original.")
        }
    }

    /// Launch Promote with role labels and name suggestions: the sheet
    /// shows the vertical naming list — Original / Lossless edition / … —
    /// each row editable, empty = keep that file's name (Rick 2026-08-19).
    private func promote(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        var titles: [UUID: String] = [:]
        var roles: [UUID: String] = [:]
        let a = job.assessment
        for id in ids {
            guard let r = job.record(for: id) else { continue }
            model.noteMissingFileForUserAction(r)
            roles[id] = roleLabel(forInstance: id, in: a)
            // The prepare-strip name applies to the ORIGINAL row; the
            // companion/edit rows start empty (= keep) unless generic.
            if id == a?.recommendedInstanceID {
                if let t = VideoScanModel.normalizedTitle(archiveTitle) { titles[id] = t }
            } else if ArchiveNameAdvisor.isGenericStem((r.filename as NSString).deletingPathExtension),
                      let t = VideoScanModel.normalizedTitle(archiveTitle) {
                titles[id] = t          // inherit the family name when its own is noise
            }
        }
        model.requestPromote(recordIDs: ids, archiveTitles: titles, roleLabels: roles)
        MainWindowHelper.shared.openMainWindow()   // the Promote sheet attaches to the main window root
    }

    /// The naming row's label for one instance: its representation's role,
    /// worded the way Rick asked (Original / Lossless edition / Edit copy).
    private func roleLabel(forInstance id: UUID, in a: CopyFamilyAssessment?) -> String {
        guard let a, let rep = a.representations.first(where: { r in r.instances.contains { $0.id == id } })
        else { return "File" }
        switch rep.role {
        case .originalSource, .presumedOriginal: return "Original"
        case .preservationCompanion:             return "Lossless edition"
        case .editingDerivative:                 return "Edit copy"
        case .accessCopy:                        return "Access copy"
        case .unconfirmedVariant:                return "Variant"
        }
    }

    // MARK: Prepare for archive (Rick 2026-08-19)

    /// Three checks before the buttons: date · audio · name. Green when
    /// good; orange with the fix path when not. The name field renames the
    /// ARCHIVE COPY only, and every entry of the same promote inherits it.
    private func prepareStrip(_ a: CopyFamilyAssessment) -> some View {
        let recRecord = a.recommendedInstanceID.flatMap { job.record(for: $0) }
        let readiness = recRecord.map { ArchiveReadiness.assess(record: $0) }
        return VStack(alignment: .leading, spacing: 6) {
            Text("PREPARE FOR ARCHIVE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            if let readiness, let rec = recRecord {
                let hint = ArchivePathResolver.facts(for: rec).dateHint
                let dateText = hint.manifestDate.isEmpty ? "unknown" : hint.manifestDate
                checkRow(ok: readiness.date == .known,
                         okText: "Date: \(dateText)",
                         fixText: readiness.date == .undated
                            ? "Date: unknown — it will file under Undated/ (set a date in the Inspector to place it in its decade)"
                            : "Date: \(dateText) (low confidence — confirm it in the Inspector)")
                checkRow(ok: readiness.audio == .verifiedOK || readiness.audio == .noAudioTrack,
                         okText: readiness.audio == .noAudioTrack ? "Audio: none (video-only)" : "Audio: verified OK",
                         fixText: {
                             if case .verifiedProblem(let note) = readiness.audio { return "Audio: problem — \(note)" }
                             return "Audio: not verified yet — use Verify Audio First below"
                         }())
                nameRow(rec)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }

    private func checkRow(ok: Bool, okText: String, fixText: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
                .font(.system(size: 12))
                .padding(.top, 1)
            Text(ok ? okText : fixText)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nameRow(_ rec: VideoRecord) -> some View {
        let stem = (rec.filename as NSString).deletingPathExtension
        let generic = ArchiveNameAdvisor.isGenericStem(stem)
        let titled = VideoScanModel.normalizedTitle(archiveTitle) != nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: (!generic || titled) ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle((!generic || titled) ? Color.green : Color.orange)
                    .font(.system(size: 12))
                Text(generic ? "Name: “\(stem)” is generic — name it for the archive:"
                             : "Name: “\(stem)”  ·  rename on the way (optional):")
                    .font(.system(size: 12))
                TextField("e.g. CapeCodVacation", text: $archiveTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: 240)
                    .accessibilityIdentifier("assessCopies.archiveName")
            }
            Text(namePreview(rec))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .padding(.leading, 18)
        }
        .onAppear {
            if archiveTitle.isEmpty, generic,
               let s = ArchiveNameAdvisor.suggestedTitle(people: rec.taggedPeople, tags: rec.tags) {
                archiveTitle = s
            }
        }
    }

    /// Live preview of the archive filename this record would get. The
    /// master keeps its name; only the verified copy is named this.
    private func namePreview(_ rec: VideoRecord) -> String {
        let facts = ArchivePathResolver.facts(for: rec)
        let rel = ArchivePathResolver.baseRelativePath(
            facts: facts, title: VideoScanModel.normalizedTitle(archiveTitle))
        return "archive copy → \(rel)   (the original file is never renamed)"
    }
}
