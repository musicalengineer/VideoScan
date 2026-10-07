// InspectorPanel+Sections.swift
// One `@ViewBuilder` per inspector section, in the order `InspectorPanel.body`
// stacks them (refactor R4, GH #281). Moved out of the 424-line body
// mechanically: each builder holds the old inline block unchanged, with its
// show/hide test and label text asked of `InspectorPanelRules`.
//
// (`@ViewBuilder func … -> some View` ≈ a C++ function returning `auto`
// whose body is a list of child views; the `if` inside becomes an optional
// child, exactly as it was inline.)

import SwiftUI

extension InspectorPanel {

    // MARK: - Header

    @ViewBuilder
    func headerSection(_ rec: VideoRecord) -> some View {
        // Filename header
        VStack(alignment: .leading, spacing: 4) {
            Text(rec.filename)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .padding(.top, 12)
            streamBadges(rec)
            // Star rating
            HStack(spacing: 6) {
                Text("Rating")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                StarRatingView(rating: Binding(
                    get: { rec.starRating },
                    set: { rec.starRating = $0 }
                ), onCommit: onRecordEdited)
            }
            // Volume name — prominent.
            // Use `displayVolumeLabel` so folder scans show as
            // "Volume > Folder" (e.g. "M4drive > rickb"), matching
            // the catalog table's Volume column. The old
            // VolumeReachability.volumeName(forPath:) helper
            // collapses any "/Users/<X>/..." path to "<X>",
            // hiding the actual volume — see catalog with 125
            // records under /Users/rickb that all appeared as
            // just "rickb" in this inspector.
            HStack(spacing: 4) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                Text(rec.displayVolumeLabel)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
            }
            .padding(.top, 2)
            // Avid identity — tape and clip name at a glance
            avidIdentityCard(rec)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func streamBadges(_ rec: VideoRecord) -> some View {
        HStack(spacing: 8) {
            Text(InspectorPanelRules.streamBadgeText(rec))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(streamTypeColor(rec.streamType))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(streamTypeColor(rec.streamType).opacity(0.12))
                )
            // "NO AUDIO" on an unpaired video-only file, "NO VIDEO" on an
            // unpaired audio-only one (the two cannot both apply).
            if let missing = InspectorPanelRules.missingStreamBadge(rec) {
                Text(missing)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.orange.opacity(0.12))
                    )
            }
        }
    }

    @ViewBuilder
    private func avidIdentityCard(_ rec: VideoRecord) -> some View {
        if InspectorPanelRules.showsAvidIdentity(rec) {
            VStack(alignment: .leading, spacing: 3) {
                if !rec.avidTapeName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "recordingtape")
                            .font(.system(size: 10))
                        Text(rec.avidTapeName)
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                if !rec.avidClipName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 10))
                        Text(rec.avidClipName)
                            .font(.system(size: 11))
                    }
                }
            }
            .foregroundColor(.cyan)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.cyan.opacity(0.08))
            )
            .padding(.top, 4)
        }
    }

    // MARK: - Technical

    func generalSection(_ rec: VideoRecord) -> some View {
        inspectorSection("General", systemImage: "doc") {
            inspectorRow("Size", rec.sizeDisplay)
            inspectorRow("Duration", rec.duration)
            inspectorRow("Container", rec.container)
            inspectorRow("Extension", rec.ext)
        }
    }

    func videoSection(_ rec: VideoRecord) -> some View {
        inspectorSection("Video", systemImage: "film") {
            inspectorRow("Resolution", rec.resolution)
            inspectorRow("Codec", rec.videoCodec)
            inspectorRow("Frame Rate", rec.frameRate)
            inspectorRow("Bitrate", rec.videoBitrate)
            inspectorRow("Total Bitrate", rec.totalBitrate)
            inspectorRow("Color Space", rec.colorSpace)
            inspectorRow("Bit Depth", rec.bitDepth)
            inspectorRow("Scan Type", rec.scanType)
        }
    }

    func audioSection(_ rec: VideoRecord) -> some View {
        inspectorSection("Audio", systemImage: "speaker.wave.2") {
            inspectorRow("Codec", rec.audioCodec)
            inspectorRow("Channels", rec.audioChannels)
            inspectorRow("Sample Rate", rec.audioSampleRate)
        }
    }

    // MARK: - What Rick has said (people, tags, when, where, history)

    func familyTagsSection(_ rec: VideoRecord) -> some View {
        inspectorSection("Family Tags", systemImage: "person.crop.circle") {
            InspectorFamilyTagsView(record: rec)
        }
    }

    // Workflow tags (2026-07-23) — chip row + ⊕ add menu.
    // Sits right under Family Tags: this whole
    // neighborhood is "what Rick has said about this
    // record" (people, tags, dates). `.id(rec.id)` resets
    // the view's custom-entry draft when selection moves.
    func workflowTagsSection(_ rec: VideoRecord) -> some View {
        inspectorSection("Tags", systemImage: "tag") {
            InspectorWorkflowTagsView(record: rec)
                .id(rec.id)
        }
    }

    // "When and who" area: the date entry sits right under
    // Family Tags (GH #117 — the future tag-person picker
    // and this share one neighborhood). `.id(rec.id)`
    // reseeds the draft text when the selection changes.
    func whenSection(_ rec: VideoRecord) -> some View {
        inspectorSection("When Was This?", systemImage: "calendar.badge.clock") {
            InspectorDateView(record: rec)
                .id(rec.id)
        }
    }

    // "Where" sits right under "When" (Rick 2026-09-12):
    // the hand-entered place, a near-clone of the date
    // entry with the same best-guess / I'm-sure control.
    func whereSection(_ rec: VideoRecord) -> some View {
        inspectorSection("Where Was This?", systemImage: "mappin.and.ellipse") {
            InspectorPlaceView(record: rec)
                .id(rec.id)
        }
    }

    // History (Media Ledger, stage 2 — Rick 2026-09-12):
    // dated sentences for this record, newest first, read
    // off-main and cached per record by the ledger. The
    // view does no file I/O and no O(records) work.
    func historySection(_ rec: VideoRecord) -> some View {
        inspectorSection("History", systemImage: "clock.arrow.circlepath") {
            InspectorHistoryView(record: rec)
                .id(rec.id)
        }
    }

    // Dossier — captions, transcript, OCR text, OCR dates,
    // inferred date. Only shown when the record has been
    // processed by the dossier pipeline so empty rows don't
    // clutter the inspector for un-dossiered records.
    @ViewBuilder
    func dossierSection(_ rec: VideoRecord) -> some View {
        if InspectorPanelRules.showsDossier(rec) {
            inspectorSection("Dossier", systemImage: "doc.text.magnifyingglass") {
                InspectorDossierView(record: rec)
            }
        }
    }

    func timestampsSection(_ rec: VideoRecord) -> some View {
        inspectorSection("Timestamps", systemImage: "calendar") {
            // Filesystem dates stay (Finder parity) but are never
            // used for archive placement; the embedded stamp is.
            if let embedded = rec.embeddedCreationDate {
                inspectorRow("Embedded", InspectorPanelRules.embeddedDateText(embedded))
            }
            if let origin = rec.originDescription {
                inspectorRow("Origin", origin)
            }
            inspectorRow("Created", rec.dateCreated)
            inspectorRow("Modified", rec.dateModified)
            inspectorRow("Timecode", rec.timecode)
            inspectorRow("Tape Name", rec.tapeName)
        }
    }

    // MARK: - Relations (pair, trim, archive, Angel, repair)

    @ViewBuilder
    func correlationSection(_ rec: VideoRecord) -> some View {
        if InspectorPanelRules.showsCorrelation(rec) {
            inspectorSection("Correlation", systemImage: "arrow.triangle.2.circlepath") {
                if let paired = rec.pairedWith {
                    pairedWithRow(paired)
                }
                if let conf = rec.pairConfidence {
                    HStack(spacing: 6) {
                        Text("Confidence")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .trailing)
                        Circle()
                            .fill(conf.textColor)
                            .frame(width: 8, height: 8)
                        Text(conf.rawValue)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(conf.textColor)
                        Spacer()
                    }
                }
            }
        }
    }

    private func pairedWithRow(_ paired: VideoRecord) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("Paired With")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    onSelectRecord?(paired.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: paired.streamType == .audioOnly
                              ? "waveform" : "film")
                            .font(.system(size: 9))
                        Text(paired.filename)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                Text(paired.directory)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
        }
    }

    // Trim provenance — same minimal-indicator convention
    // as the Correlation section's "Paired With" row.
    @ViewBuilder
    func trimSection(_ rec: VideoRecord) -> some View {
        if InspectorPanelRules.showsTrim(rec, hasDerivatives: !trimDerivatives.isEmpty) {
            inspectorSection("Trim", systemImage: "scissors") {
                if let inSec = rec.trimInSeconds, let outSec = rec.trimOutSeconds {
                    if let source = trimSource {
                        trimLinkRow(label: "Trimmed from", target: source)
                    }
                    inspectorRow("Kept",
                                 InspectorPanelRules.trimKeptText(inSeconds: inSec, outSeconds: outSec))
                }
                ForEach(trimDerivatives, id: \.id) { derived in
                    trimLinkRow(label: "Trimmed version", target: derived)
                }
            }
        }
    }

    // Master Archive (docs/archive_promotion_workflow.md
    // §4): "Master copy ✓ · Reveal" on sources with a
    // promoted copy; "Promoted from … · Reveal source" on
    // archive copies. Both links jump to the other record;
    // Reveal opens Finder on the file.
    @ViewBuilder
    func masterArchiveSection(_ rec: VideoRecord) -> some View {
        if InspectorPanelRules.showsMasterArchive(masterCopy: masterCopy, promotionSource: promotionSource) {
            inspectorSection("Master Archive", systemImage: "archivebox") {
                // Rick 2026-08-25: "Archived on [Date] to [Volume] in
                // nice bold green" — the one line that says this
                // content is safe, on originals AND on their copies.
                if let banner = Self.archivedBanner(record: rec, masterCopy: masterCopy,
                                                    promotionSource: promotionSource) {
                    Label(banner.text, systemImage: banner.verified ? "checkmark.seal.fill" : "clock.badge.exclamationmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(banner.verified
                            ? Color(red: 0.10, green: 0.62, blue: 0.30) : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                        .accessibilityIdentifier("inspector.archivedBanner")
                }
                if let copy = masterCopy {
                    promotionLinkRow(label: InspectorPanelRules.masterCopyLabel(copy: copy, record: rec),
                                     target: copy, revealTitle: "Reveal")
                    if let fixity = copy.archiveFixity {
                        inspectorRow("Fixity", InspectorPanelRules.masterCopyFixityText(fixity))
                    }
                }
                if let source = promotionSource {
                    promotionLinkRow(label: "Promoted from", target: source, revealTitle: "Reveal source")
                }
                if let fixity = rec.archiveFixity, promotionSource != nil {
                    inspectorRow("Fixity", InspectorPanelRules.archiveCopyFixityText(fixity))
                }
            }
        }
    }

    // Archive Angel phase 2: what the background sweep
    // thinks — a candidate with its why-lines, or the
    // floor reason. Machine tier; the Angel batch decides
    // nothing, Rick does.
    @ViewBuilder
    func angelSection() -> some View {
        if let ev = angelEvidence,
           InspectorPanelRules.showsAngelAssessment(hasEvidence: true, masterCopy: masterCopy,
                                                    promotionSource: promotionSource) {
            inspectorSection("Archive Angel Assessment", systemImage: "sparkles") {
                if let r = ev.rejection {
                    Text("Excluded — " + r.rawValue)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("inspector.angelRejection")
                } else {
                    Text("AAA grade \(ev.grade.rawValue) (\(ev.score)) — \(ev.grade.label)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .accessibilityIdentifier("inspector.angelScore")
                    ForEach(Array(ev.lines.prefix(4).enumerated()), id: \.offset) { _, line in
                        Text("· " + line.line)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // Repair lifecycle (GH #132) — shown on repair
    // copies (awaiting or confirmed) and on superseded
    // originals. The confirm button is the same
    // one-click verb the context menu offers.
    @ViewBuilder
    func repairSection(_ rec: VideoRecord) -> some View {
        if InspectorPanelRules.showsRepair(rec) {
            inspectorSection("Repair", systemImage: "checkmark.seal") {
                if let source = repairSource {
                    repairLinkRow(label: "Repaired from", target: source)
                }
                if let copy = repairCopy {
                    repairLinkRow(label: "Repaired copy", target: copy)
                }
                if let status = InspectorPanelRules.repairStatusText(rec) {
                    inspectorRow("Status", status)
                }
                // Purged / set-aside repair copies are not
                // confirmable (QA M1) — the model refuses
                // too; this keeps the button honest.
                if InspectorPanelRules.showsConfirmRepair(rec, hasRepairSource: repairSource != nil) {
                    Button("Sounds Good — Confirm Repair") {
                        onConfirmRepair?(rec.id)
                    }
                    .controlSize(.small)
                    .help("Keep this repaired copy as the one to use. The original is hidden from the everyday view — never deleted — and your tags, notes, people, and ratings carry over.")
                    .accessibilityIdentifier("inspector.confirmRepair")
                }
            }
        }
    }

    // MARK: - Duplicates

    @ViewBuilder
    func duplicatesSection(_ rec: VideoRecord) -> some View {
        if InspectorPanelRules.showsDuplicates(rec) {
            inspectorSection("Duplicates", systemImage: "doc.on.doc") {
                if rec.duplicateDisposition != .none {
                    HStack(spacing: 6) {
                        Text("Status")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .trailing)
                        Circle()
                            .fill(rec.duplicateDisposition.textColor)
                            .frame(width: 8, height: 8)
                        Text(InspectorPanelRules.duplicateStatusText(rec))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(rec.duplicateDisposition.textColor)
                        Spacer()
                    }
                }
                inspectorRow("Reasons", rec.duplicateReasons)
                if let conf = rec.duplicateConfidence {
                    HStack(spacing: 6) {
                        Text("Confidence")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .trailing)
                        Circle()
                            .fill(conf.textColor)
                            .frame(width: 8, height: 8)
                        Text(conf.rawValue)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(conf.textColor)
                        Spacer()
                    }
                }

                // Show all copies in this duplicate group
                duplicateGroupList(rec)
            }
        }
    }

    @ViewBuilder
    private func duplicateGroupList(_ rec: VideoRecord) -> some View {
        if !duplicateGroupMembers.isEmpty {
            let thisVolume = VolumeReachability.volumeName(forPath: rec.fullPath)

            Divider().padding(.vertical, 4)

            Text(InspectorPanelRules.duplicateGroupHeader(otherMembers: duplicateGroupMembers.count))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary)
                .padding(.leading, 4)

            // This record (selected)
            duplicateCopyRow(
                filename: rec.filename,
                volumeName: thisVolume,
                directory: (rec.fullPath as NSString).deletingLastPathComponent,
                disposition: rec.duplicateDisposition,
                isSameVolume: true,
                isSelected: true
            )

            // Other group members
            ForEach(duplicateGroupMembers, id: \.id) { member in
                let memberVolume = VolumeReachability.volumeName(forPath: member.fullPath)
                let sameVolume = (memberVolume == thisVolume)
                duplicateCopyRow(
                    filename: member.filename,
                    volumeName: memberVolume,
                    directory: (member.fullPath as NSString).deletingLastPathComponent,
                    disposition: member.duplicateDisposition,
                    isSameVolume: sameVolume,
                    isSelected: false
                )
            }
        }
    }

    // MARK: - Avid, notes, location

    @ViewBuilder
    func avidProjectSection(_ rec: VideoRecord) -> some View {
        if InspectorPanelRules.showsAvidProject(rec) {
            inspectorSection("Avid Project", systemImage: "film.stack") {
                inspectorRow("Clip Name", rec.avidClipName)
                inspectorRow("Mob Type", rec.avidMobType)
                inspectorRow("Bin File", rec.avidBinFile)
                inspectorRow("Tape", rec.avidTapeName)
                inspectorRow("Tracks", rec.avidTracks)
                inspectorRow("Edit Rate", InspectorPanelRules.editRateText(rec.avidEditRate))
                inspectorCopyableRow("Mob ID", rec.avidMobID)
                inspectorCopyableRow("Material UUID", rec.avidMaterialUUID)
                inspectorCopyableRow("Original Path", rec.avidMediaPath)
            }
        }
    }

    // userNotes split (2026-07-23): YOUR note text gets
    // its own section; the machine/probe notes keep the
    // original "Notes" section below (unchanged styling,
    // including the red ffprobe-failure treatment).
    @ViewBuilder
    func userNotesSection(_ rec: VideoRecord) -> some View {
        if InspectorPanelRules.showsUserNotes(rec) {
            inspectorSection("Your Notes", systemImage: "note.text") {
                Text(rec.userNotes)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    func notesSection(_ rec: VideoRecord) -> some View {
        if InspectorPanelRules.showsNotes(rec) {
            inspectorSection("Notes", systemImage: "exclamationmark.bubble") {
                Text(rec.notes)
                    .font(.system(size: 12))
                    .foregroundColor(rec.streamType == .ffprobeFailed ? .red : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func locationSection(_ rec: VideoRecord) -> some View {
        inspectorSection("Location", systemImage: "folder") {
            inspectorCopyableRow("Path", rec.fullPath)
            inspectorRow("Directory", rec.directory)
            inspectorRow("MD5 (partial)", rec.partialMD5)
            // File signature — the identity duplicate
            // detection runs on. Says "not computed yet"
            // rather than showing blank: an empty row reads
            // as "no signature exists for this file", when
            // the truth is "nobody has looked" (Rick
            // 2026-08-12).
            inspectorCopyableRow("File Signature", rec.contentHashDisplay)
        }
    }

    // MARK: - No selection

    var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.4))
            Text("No Selection")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Text("Select a file to view details")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }
}
