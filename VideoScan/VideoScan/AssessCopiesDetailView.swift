// AssessCopiesDetailView.swift
// The expanded row for an Assess Copies job in the Media File
// Operations window (Promote-Helper slice 2): verdict paragraph,
// cautions, one card per representation (role · signature · locations ·
// recommended instance · reason), and the action buttons that hand off
// to the EXISTING verbs — Promote (unchanged safe executor), Verify
// Audio, Balance Audio, Transcode (companion / access copy).
//
// 2026-08-26 (Rick: "the helper should have a button Verify/Fix Audio
// and, if the audio is not balanced, it balances it"): the Verify
// verdict now shows INLINE under the actions with the probe's numbers;
// a fixable verdict swaps the Verify button for Balance Audio (progress
// while it runs), and "Verify and Fix Audio" chains the two. The
// state lives in the job's VerifyThenBalanceCoordinator
// (HelperAudioRepair.swift), so it survives collapsing the row.

import SwiftUI

struct AssessCopiesDetailView: View {
    @ObservedObject var job: AssessCopiesJob
    @EnvironmentObject var model: VideoScanModel
    /// Forwarded only (to the Transcode sheet and the job's audio
    /// coordinator) — the panel reads job/coordinator state, not the
    /// Center's own published fields.
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject var center: MediaFileOperationsCenter

    @State private var transcodeRequest: TranscodeRequest?
    @State private var expandedReps: Set<String> = []
    /// TO BE ARCHIVED worksheet (Rick 2026-08-19): archive names per
    /// role row. Editing the Original auto-derives the companion/edit
    /// names (base_modernized_YYYY / base_edit) until the user touches
    /// those fields themselves. Renames apply to the ARCHIVE COPY only.
    @State private var names: [UUID: String] = [:]
    @State private var userTouched: Set<UUID> = []
    /// The info cards are the reference, not the focus — collapsed by
    /// default so the worksheet leads (Rick: "a bit busy").
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let a = job.assessment {
                summary(a)
                if !a.cautions.isEmpty { cautions(a) }
                if a.recommendedInstanceID != nil {
                    prepareStrip(a)
                }
                actions(a)
                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(a.representations) { rep in
                            representationCard(rep, assessment: a)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("All copies found (\(a.representations.count) representations, \(a.locationCount) locations)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
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

    /// Role chip fills — dark enough to carry white small-caps text
    /// (Rick 2026-08-19: "I can barely read the words"; same luminance
    /// bar as the MFO badge palette).
    private func roleColor(_ r: CopyRole) -> Color {
        switch r {
        case .originalSource:        return Color(red: 0.26, green: 0.22, blue: 0.62)  // deep indigo
        case .presumedOriginal:      return Color(red: 0.42, green: 0.20, blue: 0.58)  // dark violet
        case .repairedCopy:          return Color(red: 0.55, green: 0.30, blue: 0.05)  // dark amber
        case .preservationCompanion: return Color(red: 0.05, green: 0.42, blue: 0.22)  // forest green
        case .editingDerivative:     return Color(red: 0.00, green: 0.40, blue: 0.44)  // dark teal
        case .accessCopy:            return Color(red: 0.08, green: 0.32, blue: 0.72)  // cobalt
        case .unconfirmedVariant:    return Color(red: 0.72, green: 0.36, blue: 0.00)  // burnt orange
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
        var repaired: CopyRepresentation?
        var readOnly: Bool
        var recReachable: Bool { recRecord.map { VolumeReachability.isReachable(path: $0.fullPath) } ?? false }
    }

    private func actions(_ a: CopyFamilyAssessment) -> some View {
        let recID = a.recommendedInstanceID
        // LIVE record first (verify persists its verdict on the model's
        // instance; the job's map is a start-time snapshot).
        let recRecord = recID.flatMap { model.record(forID: $0) ?? job.record(for: $0) }
        let ctx = ActionContext(rec: a.recommendedRepresentation,
                                recID: recID,
                                recRecord: recRecord,
                                companion: a.representations.first { $0.role == .preservationCompanion },
                                repaired: a.representations.first { $0.role == .repairedCopy },
                                readOnly: model.isReadOnly)
        // One coordinator per recommended record, owned by the job.
        // Idempotent lookup-or-create; it publishes nothing on creation,
        // so calling it from the body cannot loop the render.
        let coordinator = recRecord.map { job.audioCoordinator(for: $0, center: center, model: model) }
        let repairedExists = ctx.repaired != nil || coordinator?.phase == .balanced
        let composed = HelperAudioActions.compose(base: a.actions,
                                                  outcome: coordinator?.outcome,
                                                  repairedCopyExists: repairedExists)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(composed, id: \.rawValue) { action in
                    actionButton(action, ctx, coordinator: coordinator)
                }
                Spacer()
            }
            if let coordinator {
                HelperAudioVerdictLine(coordinator: coordinator,
                                       repairedCopyName: ctx.repaired?.instances.first?.filename)
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: CopyFamilyAction, _ c: ActionContext,
                              coordinator: VerifyThenBalanceCoordinator?) -> some View {
        switch action {
        case .verifyAudioFirst:
            if let coordinator {
                HelperVerifyButtons(coordinator: coordinator)
            }
        case .balanceAudio:
            if let coordinator {
                HelperBalanceButton(coordinator: coordinator, readOnly: c.readOnly)
            }
        case .promoteRecommendedOriginal:
            Button {
                if let id = c.recID { promote([id]) }
            } label: { Label("Promote Recommended Original", systemImage: "archivebox.fill") }
            .disabled(c.recID == nil || c.readOnly)
            .help("Hands the recommended copy to Promote — verified byte-for-byte into the Master Archive; the original is never moved or changed.")
        case .promoteOriginalAndRepaired:
            Button {
                var ids: [UUID] = []
                if let id = c.recID { ids.append(id) }
                if let rid = c.repaired?.recommendedInstanceID { ids.append(rid) }
                promote(ids)
            } label: { Label("Promote Original + Repaired Copy", systemImage: "archivebox.fill") }
            .disabled(c.recID == nil || c.readOnly)
            .help("The repaired copy is the playable master; the untouched original is the source of record. Both go in, both verified.")
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
        stampFamilyUserDateIfMissing(ids)
        var titles: [UUID: String] = [:]
        var roles: [UUID: String] = [:]
        let a = job.assessment
        for id in ids {
            guard let r = model.record(forID: id) ?? job.record(for: id) else { continue }
            model.noteMissingFileForUserAction(r)
            roles[id] = roleLabel(forInstance: id, in: a)
            if let t = VideoScanModel.normalizedTitle(names[id]) { titles[id] = t }
        }
        // Raise the main window FIRST so the confirmation sheet animates
        // in front of the MFO window rather than opening buried behind it
        // (Rick 2026-08-19: "I thought it was hung").
        MainWindowHelper.shared.openMainWindow()
        model.requestPromote(recordIDs: ids, archiveTitles: titles, roleLabels: roles)
    }

    /// The copy family's best hand-entered date, from LIVE records.
    /// Known beats estimated; more precise (longer canonical) beats less;
    /// remaining ties resolve lexicographically so the answer is stable.
    private func familyBestUserDate() -> (date: String, confidence: String)? {
        var best: (date: String, confidence: String)?
        for id in job.familyByID.keys {
            guard let r = model.record(forID: id) ?? job.record(for: id),
                  let d = r.userDate else { continue }
            let cand = (date: d,
                        confidence: r.userDateConfidence ?? UserDateConfidence.estimated.rawValue)
            guard let b = best else { best = cand; continue }
            let candKnown = cand.confidence == UserDateConfidence.known.rawValue
            let bestKnown = b.confidence == UserDateConfidence.known.rawValue
            if candKnown != bestKnown { if candKnown { best = cand }; continue }
            if cand.date.count != b.date.count {
                if cand.date.count > b.date.count { best = cand }; continue
            }
            if cand.date < b.date { best = cand }
        }
        return best
    }

    /// The recording's date rides the promote: records being promoted
    /// that lack a user date inherit the family's best one (same direct-
    /// mutation + mutated-notification write path as InspectorDateView),
    /// so the check row, the destination folder and the timeline agree.
    private func stampFamilyUserDateIfMissing(_ ids: [UUID]) {
        guard let fam = familyBestUserDate() else { return }
        var stamped = false
        for id in ids {
            guard let r = model.record(forID: id) ?? job.record(for: id),
                  r.userDate == nil else { continue }
            r.userDate = fam.date
            r.userDateConfidence = fam.confidence
            stamped = true
        }
        if stamped {
            NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
        }
    }

    /// The naming row's label for one instance: its representation's role,
    /// worded as Rick's ledger (2026-08-20): Master / Lossless Copy /
    /// Access Copy — same vocabulary as the worksheet, one language
    /// everywhere.
    private func roleLabel(forInstance id: UUID, in a: CopyFamilyAssessment?) -> String {
        guard let a, let rep = a.representations.first(where: { r in r.instances.contains { $0.id == id } })
        else { return "File" }
        switch rep.role {
        case .originalSource, .presumedOriginal: return "Master"
        case .repairedCopy:                      return "Repaired Copy"
        case .preservationCompanion:             return "Lossless Copy"
        case .editingDerivative:                 return "Edit Copy"
        case .accessCopy:                        return "Access Copy"
        case .unconfirmedVariant:                return "Variant"
        }
    }

    // MARK: TO BE ARCHIVED (Rick 2026-08-19)

    /// One row per file headed to the archive: Original · Modern Lossless
    /// Copy · Copy for Editing — each with the name its ARCHIVE COPY will
    /// carry (masters on disk never renamed; the old name is recorded as
    /// provenance on the copy). Date and audio checks sit on top: the
    /// three things to settle before promoting.
    private func prepareStrip(_ a: CopyFamilyAssessment) -> some View {
        let rows = worksheetRows(a)
        // LIVE record first, captured instance as fallback: the job's
        // familyByID is a start-time snapshot, so an Inspector edit made
        // while this panel is open (Rick set the date, panel kept
        // complaining — 2026-08-20) must be re-read from the model.
        let recRecord = a.recommendedInstanceID.flatMap { id in
            model.record(forID: id) ?? job.record(for: id)
        }
        // A hand-entered date anywhere in the family is the RECORDING's
        // date — the election may recommend a twin Rick never dated.
        let familyDate = recRecord?.userDate == nil ? familyBestUserDate() : nil
        let readiness = recRecord.map { ArchiveReadiness.assess(record: $0, familyUserDate: familyDate) }
        return VStack(alignment: .leading, spacing: 10) {
            Label("TO BE ARCHIVED", systemImage: "archivebox.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .tracking(0.5)
            if let readiness, let rec = recRecord {
                let hint = ArchivePathResolver.facts(for: rec).dateHint
                // Human surface → friendly form ("November 1984", "14 Nov
                // 1984"); the manifest and on-disk names stay ISO. The
                // family's date shows when the recommended twin has none —
                // promote stamps it (see promote(_:)) so disk agrees.
                let dateText: String = {
                    if let fam = familyDate { return UserDateEntry.friendlyDisplay(fam.date) }
                    return hint.manifestDate.isEmpty
                        ? "unknown" : UserDateEntry.friendlyDisplay(hint.manifestDate)
                }()
                HStack(spacing: 16) {
                    checkRow(ok: readiness.date == .known,
                             okText: "Date \(dateText)",
                             fixText: readiness.date == .undated
                                ? "Date unknown — files under Undated/ (set it in the Inspector)"
                                : "Date \(dateText) — low confidence, confirm in the Inspector")
                    checkRow(ok: readiness.audio == .verifiedOK || readiness.audio == .noAudioTrack,
                             okText: readiness.audio == .noAudioTrack ? "No audio track" : "Audio verified",
                             fixText: {
                                 if case .verifiedProblem(let note) = readiness.audio { return "Audio problem — \(note)" }
                                 return "Audio not verified — Verify Audio below"
                             }())
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(rows, id: \.id) { row in
                    worksheetRow(row)
                }
            }
            Text("Masters on disk are never renamed — the name applies to the verified archive copy, and the original filename is recorded on it as provenance.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
        .onAppear { seedNames(rows) }
    }

    private struct WorksheetRow: Identifiable {
        let id: UUID          // record id
        let label: String     // Master / Repaired Copy / Lossless Copy / Edit Copy
        /// What this copy is FOR — "which one is for editing and
        /// playback" must be readable at a glance (Rick 2026-08-20).
        let purpose: String
        let record: VideoRecord
        let isOriginal: Bool
    }

    /// The ledger Rick asked for: Master, then each companion with its
    /// purpose spelled out. LIVE records first (the job's map is a
    /// start-time snapshot; see prepareStrip).
    private func worksheetRows(_ a: CopyFamilyAssessment) -> [WorksheetRow] {
        func live(_ id: UUID) -> VideoRecord? { model.record(forID: id) ?? job.record(for: id) }
        var rows: [WorksheetRow] = []
        if let id = a.recommendedInstanceID, let r = live(id) {
            rows.append(WorksheetRow(id: id, label: "Master",
                                     purpose: "the original — preserved untouched",
                                     record: r, isOriginal: true))
        }
        for rep in a.representations {
            guard let iid = rep.recommendedInstanceID, let r = live(iid) else { continue }
            switch rep.role {
            case .repairedCopy:
                rows.append(WorksheetRow(id: iid, label: "Repaired Copy",
                                         purpose: "corrected audio/picture — the playable master",
                                         record: r, isOriginal: false))
            case .preservationCompanion:
                rows.append(WorksheetRow(id: iid, label: "Lossless Copy",
                                         purpose: "modern lossless, full quality — for editing",
                                         record: r, isOriginal: false))
            case .editingDerivative:
                rows.append(WorksheetRow(id: iid, label: "Edit Copy",
                                         purpose: "mezzanine — for editing",
                                         record: r, isOriginal: false))
            default: break
            }
        }
        return rows
    }

    private func worksheetRow(_ row: WorksheetRow) -> some View {
        let stem = (row.record.filename as NSString).deletingPathExtension
        let generic = ArchiveNameAdvisor.isGenericStem(stem)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(row.label)
                        .font(.system(size: 12, weight: .semibold))
                    Text(row.purpose)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .frame(width: 150, alignment: .trailing)
                TextField(generic ? "name it — “\(stem)” tells the archive nothing" : "keep “\(stem)”",
                          text: nameBinding(row))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .accessibilityIdentifier("archiveHelper.name.\(row.label)")
                if generic && VideoScanModel.normalizedTitle(names[row.id]) == nil {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .help("Generic filename — a meaningful name (people, place, occasion) makes the archive browsable.")
                }
            }
            Text(namePreview(row.record, title: VideoScanModel.normalizedTitle(names[row.id])))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .padding(.leading, 158)
        }
    }

    /// Editing the Original re-derives the untouched companion rows:
    /// base → base_modernized_YYYY / base_edit (Rick's naming scheme).
    private func nameBinding(_ row: WorksheetRow) -> Binding<String> {
        Binding(
            get: { names[row.id] ?? "" },
            set: { new in
                names[row.id] = new
                if row.isOriginal {
                    deriveCompanionNames(from: new)
                } else {
                    userTouched.insert(row.id)
                }
            })
    }

    private func deriveCompanionNames(from base: String) {
        guard let a = job.assessment else { return }
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let year = Calendar.current.component(.year, from: Date())
        for row in worksheetRows(a) where !row.isOriginal && !userTouched.contains(row.id) {
            if trimmed.isEmpty { names[row.id] = "" ; continue }
            switch row.label {
            case "Modern Lossless Copy": names[row.id] = "\(trimmed)_modernized_\(year)"
            case "Repaired Copy":        names[row.id] = "\(trimmed)_repaired"
            default:                     names[row.id] = "\(trimmed)_edit"
            }
        }
    }

    /// Seed once per assessment: suggestion from people/tags when the
    /// original's stem is generic; companions derive from it.
    private func seedNames(_ rows: [WorksheetRow]) {
        guard names.isEmpty, let original = rows.first(where: \.isOriginal) else { return }
        let stem = (original.record.filename as NSString).deletingPathExtension
        if ArchiveNameAdvisor.isGenericStem(stem),
           let s = ArchiveNameAdvisor.suggestedTitle(people: original.record.taggedPeople,
                                                     tags: original.record.tags) {
            names[original.id] = s
            deriveCompanionNames(from: s)
        }
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

    /// Live preview of the archive filename a record gets with `title`.
    private func namePreview(_ rec: VideoRecord, title: String?) -> String {
        let facts = ArchivePathResolver.facts(for: rec)
        return "→ " + ArchivePathResolver.baseRelativePath(facts: facts, title: title)
    }
}

// MARK: - Verify / Fix Audio controls (2026-08-26)

// These are separate structs (not private funcs on the panel) because
// each needs `@ObservedObject` on the coordinator / balance job to
// repaint on progress — SwiftUI only re-evaluates a view whose OWN
// observed objects change. (≈ a Qt widget subscribing to a signal:
// the subscription must belong to the widget that repaints.)

/// "Verify Audio" (two-step — Rick wants to see the verdict) plus the
/// one-click "Verify and Fix Audio" that chains a balance when fixable.
private struct HelperVerifyButtons: View {
    @ObservedObject var coordinator: VerifyThenBalanceCoordinator

    var body: some View {
        Button {
            coordinator.verify(thenBalance: false)
        } label: {
            if coordinator.phase == .verifying {
                Label { Text("Verifying…") } icon: { ProgressView().controlSize(.mini) }
            } else {
                Label("Verify Audio", systemImage: "waveform.badge.magnifyingglass")
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(coordinator.isBusy)
        .help("Diagnoses the audio track; if it's one-sided or mono, you can balance it here.")
        .accessibilityIdentifier("archiveHelper.verifyAudio")

        Button {
            coordinator.verify(thenBalance: true)
        } label: { Label("Verify and Fix Audio", systemImage: "waveform.path.badge.plus") }
        .disabled(coordinator.isBusy)
        .help("Diagnoses the track and, if it's one-sided or mono, balances it straight away — no second click. The verdict still shows here.")
        .accessibilityIdentifier("archiveHelper.verifyAndFixAudio")
    }
}

/// "Balance Audio" — shown only for a fixable verdict; turns into a
/// live progress label while the balance job runs.
private struct HelperBalanceButton: View {
    @ObservedObject var coordinator: VerifyThenBalanceCoordinator
    let readOnly: Bool

    var body: some View {
        if coordinator.phase == .balancing, let job = coordinator.balanceJob {
            HelperBalanceProgress(job: job)
        } else {
            Button {
                coordinator.balance()
            } label: { Label("Balance Audio", systemImage: "waveform.path") }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(coordinator.isBusy || readOnly)
            .help({
                let name = coordinator.plannedBalanceOutput?.lastPathComponent ?? "<name>_balanced"
                return "Copies the live channel to both speakers into \(name) beside the original (video untouched, no re-encode). The original file is never changed."
            }())
            .accessibilityIdentifier("archiveHelper.balanceAudio")
        }
    }
}

private struct HelperBalanceProgress: View {
    @ObservedObject var job: BalanceAudioJob

    var body: some View {
        HStack(spacing: 6) {
            if job.isIndeterminate {
                ProgressView().controlSize(.small)
            } else {
                ProgressView(value: job.fraction).frame(width: 90)
                Text("\(Int((job.fraction * 100).rounded()))%")
                    .font(.system(size: 11, design: .monospaced))
            }
            Text("Balancing…").font(.system(size: 12))
            Button("Cancel") { job.cancel() }.controlSize(.small)
        }
        .help(job.subtitle)
    }
}

/// The verdict line under the actions: what Verify found, with the
/// probe's numbers; the balance outcome once one ran.
private struct HelperAudioVerdictLine: View {
    @ObservedObject var coordinator: VerifyThenBalanceCoordinator
    /// Filename of an already-catalogued repaired copy, if the family
    /// holds one (the 8/19 rule — never re-offer Balance).
    let repairedCopyName: String?

    var body: some View {
        if let line = content {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: line.icon)
                    .foregroundStyle(line.color)
                    .font(.system(size: 12))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.text)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = line.detail {
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("archiveHelper.audioVerdict")
        }
    }

    private struct Line {
        var icon: String
        var color: Color
        var text: String
        var detail: String?
    }

    private var content: Line? {
        switch coordinator.phase {
        case .verifying:
            return Line(icon: "waveform.badge.magnifyingglass", color: .secondary,
                        text: "Diagnosing the audio track… (reads the whole track; a long tape takes a minute)")
        case .balancing:
            return Line(icon: "waveform.path", color: .secondary,
                        text: coordinator.balanceJob?.subtitle ?? "Balancing…")
        case .balanced:
            let name = coordinator.balancedOutputName ?? "the balanced copy"
            return Line(icon: "checkmark.circle.fill", color: .green,
                        text: "Audio balanced into \(name) — promote the original and the repaired copy together.")
        case .failed(let message):
            return Line(icon: "xmark.octagon.fill", color: .orange, text: message)
        case .idle, .verified:
            guard let outcome = coordinator.outcome else { return nil }
            switch outcome {
            case .balanced(let s):
                return Line(icon: "checkmark.circle.fill", color: .green, text: "Audio is balanced — \(s)",
                            detail: levels)
            case .fixable(_, let verdict):
                if let repairedCopyName {
                    return Line(icon: "checkmark.circle.fill", color: .green,
                                text: "\(verdict) on the original — already balanced into \(repairedCopyName).",
                                detail: levels)
                }
                return Line(icon: "exclamationmark.circle.fill", color: .orange,
                            text: "\(verdict). Balance Audio will copy the live channel to both speakers.",
                            detail: levels)
            case .refused(let reason):
                return Line(icon: "info.circle.fill", color: .secondary,
                            text: "Balance Audio won't apply — \(reason)", detail: levels)
            case .damaged(let note):
                return Line(icon: "exclamationmark.triangle.fill", color: .orange,
                            text: "Audio problem — \(note). Balance Audio can't repair this; see Verification Results in the Catalog for the repair options.")
            case .noAudio:
                return Line(icon: "speaker.slash.fill", color: .secondary,
                            text: "No audio track in this file.")
            }
        }
    }

    private var levels: String? {
        coordinator.diagnosis?.balanceAnalysis.map(HelperAudioOutcome.levelsLine)
    }
}
