// InspectorPanel.swift
// Catalog inspector panel (right-hand detail pane) and the star-rating
// control it uses. Extracted verbatim from CatalogHelpers.swift
// (refactor 2026-06-11) — behavior-preserving move, no rewrites.

import SwiftUI

// MARK: - Inspector Panel

struct InspectorPanel: View {
    let record: VideoRecord?
    /// Persistence hook for edits made INSIDE the inspector (star rating):
    /// the panel has no model access by design; the host passes
    /// `model.saveCatalogDebounced`. Defaulted for previews.
    var onRecordEdited: () -> Void = {}
    let duplicateGroupMembers: [VideoRecord]
    let previewImage: NSImage?
    let previewOfflineVolumeName: String?
    var onSelectRecord: ((UUID) -> Void)?
    /// Trim provenance (Trim Master, 2026-07-16), resolved by the CALLER
    /// (O(1) id-index lookup + memoized reverse scan — no O(records)
    /// work in this view body). `trimSource` = the record this one was
    /// trimmed from; `trimDerivatives` = trimmed versions of this one.
    var trimSource: VideoRecord?
    var trimDerivatives: [VideoRecord] = []
    /// Repair lifecycle (GH #132), resolved by the CALLER (O(1) id-index
    /// lookups — no O(records) work in this view body). `repairSource` =
    /// the record this repair copy was made from; `repairCopy` = the
    /// repaired record that superseded this one.
    var repairSource: VideoRecord?
    var repairCopy: VideoRecord?
    /// One-click confirm for the selected awaiting-confirmation repair.
    var onConfirmRepair: ((UUID) -> Void)?
    /// Master Archive (2026-08-15), resolved by the CALLER (memoized
    /// reverse index + O(1) id lookup — no O(records) work here).
    /// `masterCopy` = the archive copy promoted from this record;
    /// `promotionSource` = the record this archive copy came from.
    var masterCopy: VideoRecord?
    var promotionSource: VideoRecord?

    var body: some View {
        if let rec = record {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Filename header
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rec.filename)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .padding(.top, 12)
                        HStack(spacing: 8) {
                            Text(rec.streamType == .ffprobeFailed ? rec.isPlayable : rec.streamTypeRaw)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(streamTypeColor(rec.streamType))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(streamTypeColor(rec.streamType).opacity(0.12))
                                )
                            if rec.streamType == .videoOnly && rec.pairedWith == nil {
                                Text("NO AUDIO")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.orange.opacity(0.12))
                                    )
                            }
                            if rec.streamType == .audioOnly && rec.pairedWith == nil {
                                Text("NO VIDEO")
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
                        if rec.hasAvidMetadata && (!rec.avidTapeName.isEmpty || !rec.avidClipName.isEmpty) {
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
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                    Divider().padding(.horizontal, 16)

                    // Sections
                    inspectorSection("General", systemImage: "doc") {
                        inspectorRow("Size", rec.sizeDisplay)
                        inspectorRow("Duration", rec.duration)
                        inspectorRow("Container", rec.container)
                        inspectorRow("Extension", rec.ext)
                    }

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

                    inspectorSection("Audio", systemImage: "speaker.wave.2") {
                        inspectorRow("Codec", rec.audioCodec)
                        inspectorRow("Channels", rec.audioChannels)
                        inspectorRow("Sample Rate", rec.audioSampleRate)
                    }

                    inspectorSection("Family Tags", systemImage: "person.crop.circle") {
                        InspectorFamilyTagsView(record: rec)
                    }

                    // Workflow tags (2026-07-23) — chip row + ⊕ add menu.
                    // Sits right under Family Tags: this whole
                    // neighborhood is "what Rick has said about this
                    // record" (people, tags, dates). `.id(rec.id)` resets
                    // the view's custom-entry draft when selection moves.
                    inspectorSection("Tags", systemImage: "tag") {
                        InspectorWorkflowTagsView(record: rec)
                            .id(rec.id)
                    }

                    // "When and who" area: the date entry sits right under
                    // Family Tags (GH #117 — the future tag-person picker
                    // and this share one neighborhood). `.id(rec.id)`
                    // reseeds the draft text when the selection changes.
                    inspectorSection("When Was This?", systemImage: "calendar.badge.clock") {
                        InspectorDateView(record: rec)
                            .id(rec.id)
                    }

                    // Dossier — captions, transcript, OCR text, OCR dates,
                    // inferred date. Only shown when the record has been
                    // processed by the dossier pipeline so empty rows don't
                    // clutter the inspector for un-dossiered records.
                    if rec.dossierProcessedAt != nil {
                        inspectorSection("Dossier", systemImage: "doc.text.magnifyingglass") {
                            InspectorDossierView(record: rec)
                        }
                    }

                    inspectorSection("Timestamps", systemImage: "calendar") {
                        // Filesystem dates stay (Finder parity) but are never
                        // used for archive placement; the embedded stamp is.
                        if let embedded = rec.embeddedCreationDate {
                            inspectorRow("Embedded", InspectorDateView.embeddedFormatter.string(from: embedded) + " UTC")
                        }
                        if let origin = rec.originDescription {
                            inspectorRow("Origin", origin)
                        }
                        inspectorRow("Created", rec.dateCreated)
                        inspectorRow("Modified", rec.dateModified)
                        inspectorRow("Timecode", rec.timecode)
                        inspectorRow("Tape Name", rec.tapeName)
                    }

                    if rec.pairedWith != nil || rec.pairConfidence != nil {
                        inspectorSection("Correlation", systemImage: "arrow.triangle.2.circlepath") {
                            if let paired = rec.pairedWith {
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

                    // Trim provenance — same minimal-indicator convention
                    // as the Correlation section's "Paired With" row.
                    if rec.trimInSeconds != nil || !trimDerivatives.isEmpty {
                        inspectorSection("Trim", systemImage: "scissors") {
                            if let inSec = rec.trimInSeconds, let outSec = rec.trimOutSeconds {
                                if let source = trimSource {
                                    trimLinkRow(label: "Trimmed from", target: source)
                                }
                                inspectorRow("Kept",
                                             "\(TrimTimecode.format(inSec)) – \(TrimTimecode.format(outSec))")
                            }
                            ForEach(trimDerivatives, id: \.id) { derived in
                                trimLinkRow(label: "Trimmed version", target: derived)
                            }
                        }
                    }

                    // Master Archive (docs/archive_promotion_workflow.md
                    // §4): "Master copy ✓ · Reveal" on sources with a
                    // promoted copy; "Promoted from … · Reveal source" on
                    // archive copies. Both links jump to the other record;
                    // Reveal opens Finder on the file.
                    if masterCopy != nil || promotionSource != nil {
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
                                promotionLinkRow(label: copy.derivedFrom == rec.id ? "Master copy ✓" : "Identical copy in archive ✓",
                                                 target: copy, revealTitle: "Reveal")
                                if let fixity = copy.archiveFixity {
                                    inspectorRow("Fixity", "\(fixity.algorithm) \(fixity.digest.prefix(16))…")
                                }
                            }
                            if let source = promotionSource {
                                promotionLinkRow(label: "Promoted from", target: source, revealTitle: "Reveal source")
                            }
                            if let fixity = rec.archiveFixity, promotionSource != nil {
                                inspectorRow("Fixity", "\(fixity.algorithm) \(fixity.digest.prefix(16))… · verified \(fixity.verifiedAt.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }
                    }

                    // Repair lifecycle (GH #132) — shown on repair
                    // copies (awaiting or confirmed) and on superseded
                    // originals. The confirm button is the same
                    // one-click verb the context menu offers.
                    if rec.isAwaitingConfirmation || rec.repairConfirmedDate != nil || rec.isSuperseded {
                        inspectorSection("Repair", systemImage: "checkmark.seal") {
                            if let source = repairSource {
                                repairLinkRow(label: "Repaired from", target: source)
                            }
                            if let copy = repairCopy {
                                repairLinkRow(label: "Repaired copy", target: copy)
                            }
                            if rec.isAwaitingConfirmation {
                                inspectorRow("Status", "Waiting for your OK — play it, then confirm")
                                // Purged / set-aside repair copies are not
                                // confirmable (QA M1) — the model refuses
                                // too; this keeps the button honest.
                                if repairSource != nil, !rec.isPurged, !rec.isSetAside {
                                    Button("Sounds Good — Confirm Repair") {
                                        onConfirmRepair?(rec.id)
                                    }
                                    .controlSize(.small)
                                    .help("Keep this repaired copy as the one to use. The original is hidden from the everyday view — never deleted — and your tags, notes, people, and ratings carry over.")
                                    .accessibilityIdentifier("inspector.confirmRepair")
                                }
                            } else if let confirmedAt = rec.repairConfirmedDate {
                                inspectorRow("Status", "Confirmed \(confirmedAt.formatted(date: .abbreviated, time: .shortened))")
                            } else if rec.isSuperseded {
                                inspectorRow("Status", "Superseded — hidden from the everyday view, never deleted")
                            }
                        }
                    }

                    if rec.duplicateDisposition != .none || !rec.duplicateBestMatchFilename.isEmpty {
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
                                    Text(
                                        rec.duplicateGroupCount >= 2
                                        ? "\(rec.duplicateDisposition.rawValue) · \(rec.duplicateGroupCount) matches"
                                        : rec.duplicateDisposition.rawValue
                                    )
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
                            if !duplicateGroupMembers.isEmpty {
                                let thisVolume = VolumeReachability.volumeName(forPath: rec.fullPath)

                                Divider().padding(.vertical, 4)

                                Text("Duplicate Group (\(duplicateGroupMembers.count + 1) total)")
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
                    }

                    if rec.hasAvidMetadata {
                        inspectorSection("Avid Project", systemImage: "film.stack") {
                            inspectorRow("Clip Name", rec.avidClipName)
                            inspectorRow("Mob Type", rec.avidMobType)
                            inspectorRow("Bin File", rec.avidBinFile)
                            inspectorRow("Tape", rec.avidTapeName)
                            inspectorRow("Tracks", rec.avidTracks)
                            inspectorRow("Edit Rate", rec.avidEditRate > 0 ? String(format: "%.2f fps", rec.avidEditRate) : "")
                            inspectorCopyableRow("Mob ID", rec.avidMobID)
                            inspectorCopyableRow("Material UUID", rec.avidMaterialUUID)
                            inspectorCopyableRow("Original Path", rec.avidMediaPath)
                        }
                    }

                    // userNotes split (2026-07-23): YOUR note text gets
                    // its own section; the machine/probe notes keep the
                    // original "Notes" section below (unchanged styling,
                    // including the red ffprobe-failure treatment).
                    if !rec.userNotes.isEmpty {
                        inspectorSection("Your Notes", systemImage: "note.text") {
                            Text(rec.userNotes)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !rec.notes.isEmpty {
                        inspectorSection("Notes", systemImage: "exclamationmark.bubble") {
                            Text(rec.notes)
                                .font(.system(size: 12))
                                .foregroundColor(rec.streamType == .ffprobeFailed ? .red : .secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

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

                    Spacer(minLength: 16)
                }
            }
            .contextMenu {
                Button("Copy All Metadata") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(formatAllMetadata(rec), forType: .string)
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
        } else {
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

    // MARK: - Copy Metadata

    func formatAllMetadata(_ rec: VideoRecord) -> String {
        var lines: [String] = []
        func add(_ label: String, _ value: String) {
            guard !value.isEmpty else { return }
            lines.append("  \(label): \(value)")
        }
        func section(_ title: String) {
            if !lines.isEmpty { lines.append("") }
            lines.append("[\(title)]")
        }
        // Local copy of InspectorDossierView's formatter — keeps the
        // m:ss formatting consistent between the inspector panel and
        // the copied metadata text.
        func formatTimestamp(_ seconds: Double) -> String {
            let s = max(0, Int(seconds))
            return String(format: "%d:%02d", s / 60, s % 60)
        }

        // Header
        lines.append(rec.filename)
        lines.append("  Stream Type: \(rec.streamTypeRaw)")
        lines.append("  Volume: \(VolumeReachability.displayLabel(forPath: rec.fullPath))")
        if rec.starRating > 0 {
            lines.append("  Rating: \(String(repeating: "★", count: rec.starRating))")
        }
        if !rec.tags.isEmpty {
            lines.append("  Tags: \(rec.tags.joined(separator: ", "))")
        }
        if rec.hasAvidMetadata {
            if !rec.avidTapeName.isEmpty { add("Tape", rec.avidTapeName) }
            if !rec.avidClipName.isEmpty { add("Clip", rec.avidClipName) }
        }

        // General
        section("General")
        add("Size", rec.size)
        add("Duration", rec.duration)
        add("Container", rec.container)
        add("Extension", rec.ext)

        // Video
        section("Video")
        add("Resolution", rec.resolution)
        add("Codec", rec.videoCodec)
        add("Frame Rate", rec.frameRate)
        add("Bitrate", rec.videoBitrate)
        add("Total Bitrate", rec.totalBitrate)
        add("Color Space", rec.colorSpace)
        add("Bit Depth", rec.bitDepth)
        add("Scan Type", rec.scanType)

        // Audio
        section("Audio")
        add("Codec", rec.audioCodec)
        add("Channels", rec.audioChannels)
        add("Sample Rate", rec.audioSampleRate)

        // Timestamps
        section("Timestamps")
        if let userDate = rec.userDate {
            add("Your Date", rec.userDateStatus == .known
                ? "\(userDate) (known)" : "\(userDate) (best guess)")
        }
        if let embedded = rec.embeddedCreationDate {
            add("Embedded", InspectorDateView.embeddedFormatter.string(from: embedded) + " UTC"
                + (rec.embeddedCreationSource.map { " (\($0))" } ?? ""))
        }
        if let origin = rec.originDescription {
            add("Origin", origin)
        }
        add("Created", rec.dateCreated)
        add("Modified", rec.dateModified)
        add("Timecode", rec.timecode)
        add("Tape Name", rec.tapeName)

        // Correlation
        if rec.pairedWith != nil || rec.pairConfidence != nil {
            section("Correlation")
            if let paired = rec.pairedWith {
                add("Paired With", paired.filename)
                add("Pair Volume", VolumeReachability.displayLabel(forPath: paired.fullPath))
                add("Pair Path", paired.fullPath)
            }
            if let conf = rec.pairConfidence {
                add("Confidence", conf.rawValue)
            }
        }

        formatDuplicateSection(rec, add: add, section: section, appendLine: { lines.append($0) })
        formatAvidSection(rec, add: add, section: section)

        // Notes — your notes first, then the machine/probe notes.
        if !rec.userNotes.isEmpty {
            section("Your Notes")
            lines.append("  \(rec.userNotes)")
        }
        if !rec.notes.isEmpty {
            section("Notes")
            lines.append("  \(rec.notes)")
        }

        // Dossier — scene captions, audio transcript, OCR. Rick 2026-06-09:
        // these are the most copy-worthy fields once the record is dossier'd
        // (handy for sharing a clip's content with someone else, or for
        // pasting into a notes app). Section is omitted when there's nothing
        // worth showing to keep the output tight for non-dossier'd records.
        let hasDossierContent =
            !rec.sceneCaptions.isEmpty
            || !(rec.audioTranscript ?? "").isEmpty
            || !rec.ocrText.isEmpty
            || !rec.ocrDateCandidates.isEmpty
            || rec.inferredRecordDate != nil
        if hasDossierContent {
            section("Dossier")
            if let inferred = rec.inferredRecordDate {
                let fmt = DateFormatter()
                fmt.dateStyle = .medium
                fmt.timeStyle = .none
                var line = "  Inferred Record Date: \(fmt.string(from: inferred))"
                if let conf = rec.inferredDateConfidence {
                    line += " (confidence \(String(format: "%.2f", conf)))"
                }
                lines.append(line)
            }
            if let by = rec.dossierProcessedBy, !by.isEmpty,
               let at = rec.dossierProcessedAt {
                let fmt = DateFormatter()
                fmt.dateStyle = .short
                fmt.timeStyle = .short
                lines.append("  Processed: \(by) on \(fmt.string(from: at))")
            }
            if !rec.sceneCaptions.isEmpty {
                lines.append("")
                lines.append("  Scene Captions (\(rec.sceneCaptions.count)):")
                for cap in rec.sceneCaptions {
                    let ts = formatTimestamp(cap.timestamp)
                    lines.append("    [\(ts)] \(cap.text)")
                }
            }
            if let transcript = rec.audioTranscript, !transcript.isEmpty {
                lines.append("")
                lines.append("  Audio Transcript:")
                // Preserve as a single block — keeps the natural flow for
                // pasting elsewhere. Indent with 4 spaces.
                for textLine in transcript.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("    \(textLine)")
                }
            }
            if !rec.ocrText.isEmpty {
                lines.append("")
                lines.append("  OCR Text (\(rec.ocrText.count)):")
                for hit in rec.ocrText {
                    let ts = formatTimestamp(hit.timestamp)
                    lines.append("    [\(ts)] \(hit.text)")
                }
            }
            if !rec.ocrDateCandidates.isEmpty {
                lines.append("")
                lines.append("  OCR Date Candidates (\(rec.ocrDateCandidates.count)):")
                for hit in rec.ocrDateCandidates {
                    let ts = formatTimestamp(hit.timestamp)
                    lines.append("    [\(ts)] \(hit.text)")
                }
            }
        }

        // Location
        section("Location")
        add("Path", rec.fullPath)
        add("Directory", rec.directory)
        add("MD5 (partial)", rec.partialMD5)
        add("File Signature", rec.contentHashDisplay)

        return lines.joined(separator: "\n")
    }

    func formatDuplicateSection(
        _ rec: VideoRecord,
        add: (String, String) -> Void, section: (String) -> Void,
        appendLine: (String) -> Void
    ) {
        guard rec.duplicateDisposition != .none || !rec.duplicateBestMatchFilename.isEmpty else { return }
        section("Duplicates")
        if rec.duplicateDisposition != .none {
            let status = rec.duplicateGroupCount >= 2
                ? "\(rec.duplicateDisposition.rawValue) · \(rec.duplicateGroupCount) matches"
                : rec.duplicateDisposition.rawValue
            add("Status", status)
        }
        add("Reasons", rec.duplicateReasons)
        if let conf = rec.duplicateConfidence { add("Confidence", conf.rawValue) }
        if !duplicateGroupMembers.isEmpty {
            appendLine("")
            appendLine("  Duplicate Group (\(duplicateGroupMembers.count + 1) total):")
            let thisVol = VolumeReachability.volumeName(forPath: rec.fullPath)
            appendLine("    ★ \(rec.filename)  [\(thisVol)]  \(rec.duplicateDisposition.rawValue)")
            for member in duplicateGroupMembers {
                let vol = VolumeReachability.volumeName(forPath: member.fullPath)
                let online = VolumeReachability.isReachable(path: member.fullPath)
                appendLine("    · \(member.filename)  [\(vol)]\(online ? "" : " (offline)")  \(member.duplicateDisposition.rawValue)")
            }
        }
    }

    func formatAvidSection(
        _ rec: VideoRecord,
        add: (String, String) -> Void, section: (String) -> Void
    ) {
        guard rec.hasAvidMetadata else { return }
        section("Avid Project")
        add("Clip Name", rec.avidClipName)
        add("Mob Type", rec.avidMobType)
        add("Bin File", rec.avidBinFile)
        add("Tape", rec.avidTapeName)
        add("Tracks", rec.avidTracks)
        if rec.avidEditRate > 0 { add("Edit Rate", String(format: "%.2f fps", rec.avidEditRate)) }
        add("Mob ID", rec.avidMobID)
        add("Material UUID", rec.avidMaterialUUID)
        add("Original Path", rec.avidMediaPath)
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private func inspectorThumbnail(for rec: VideoRecord) -> some View {
        if previewOfflineVolumeName != nil {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black)
                Text("OFFLINE")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.orange)
            }
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .padding(16)
        } else if let img = previewImage {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .cornerRadius(6)
                .shadow(radius: 2)
                .frame(maxWidth: .infinity)
                .padding(16)
        } else if rec.streamType == .audioOnly {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
                Image(systemName: "waveform")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .frame(height: 80)
            .frame(maxWidth: .infinity)
            .padding(16)
        } else {
            EmptyView()
        }
    }

    // MARK: - Section Builder

    @ViewBuilder
    private func inspectorSection(_ title: String, systemImage: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            content()
                .padding(.horizontal, 16)
        }
    }

    // MARK: - Row Helpers

    /// Clickable record link for the Trim section — same visual language
    /// as the Correlation section's "Paired With" row.
    private func trimLinkRow(label: String, target: VideoRecord) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            Button {
                onSelectRecord?(target.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "scissors")
                        .font(.system(size: 9))
                    Text(target.filename)
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
            Spacer()
        }
    }

    /// Clickable record link for the Repair section — trimLinkRow's
    /// visual language with the lifecycle's swap glyph (GH #132).
    /// Master Archive link row: filename link (selects the other record)
    /// plus a small Reveal button that opens Finder on that file.
    private func promotionLinkRow(label: String, target: VideoRecord, revealTitle: String) -> some View {
        // Green = "this file is safely in the Master Archive" (Rick
        // 2026-08-16); the filename stays accent-colored because it is a
        // link that jumps to the other record.
        let verified = label.hasPrefix("Master copy")
        return HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: verified ? .semibold : .regular))
                .foregroundColor(verified ? .green : .secondary)
                .frame(width: 80, alignment: .trailing)
            Button {
                onSelectRecord?(target.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: verified ? "checkmark.seal.fill" : "star.circle")
                        .font(.system(size: 9))
                        .foregroundColor(verified ? .green : .accentColor)
                    Text(target.filename)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            Text("·").font(.system(size: 11)).foregroundColor(.secondary)
            Button(revealTitle) {
                if VolumeReachability.isReachable(path: target.fullPath) {
                    NSWorkspace.shared.selectFile(target.fullPath, inFileViewerRootedAtPath: "")
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .disabled(!VolumeReachability.isReachable(path: target.fullPath))
            .help(VolumeReachability.isReachable(path: target.fullPath)
                  ? target.fullPath
                  : "\(target.fullPath) (volume offline)")
            Spacer()
        }
    }

    private func repairLinkRow(label: String, target: VideoRecord) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            Button {
                onSelectRecord?(target.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 9))
                    Text(target.filename)
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
            Spacer()
        }
    }

    /// The "Archived on … to …" line. Pure so it can be pinned by tests.
    /// `verified` = a fixity record exists (read-back SHA-256 after the copy);
    /// without one the line goes orange and says so — a file that merely
    /// sits under the archive root is not "archived" yet.
    struct ArchivedBanner: Equatable {
        let text: String
        let verified: Bool
    }

    nonisolated static func archivedBanner(
        record: VideoRecord, masterCopy: VideoRecord?, promotionSource: VideoRecord?
    ) -> ArchivedBanner? {
        // The archive-side record is either the copy of this source, or
        // this record itself when it IS the archive copy.
        let archived: VideoRecord? = masterCopy ?? (promotionSource != nil ? record : nil)
        guard let archived else { return nil }
        let volume: String = {
            if !archived.scanContext.volumeName.isEmpty { return archived.scanContext.volumeName }
            let parts = archived.fullPath.split(separator: "/").map(String.init)
            if parts.count >= 2, parts[0] == "Volumes" { return parts[1] }
            return archived.masterLocation.isEmpty
                ? "the Master Archive"
                : URL(fileURLWithPath: archived.masterLocation).lastPathComponent
        }()
        let identical = masterCopy != nil && masterCopy?.derivedFrom != record.id
        let via = identical ? " (identical copy)" : ""
        if let fixity = archived.archiveFixity {
            let when = fixity.verifiedAt.formatted(date: .abbreviated, time: .omitted)
            return ArchivedBanner(text: "Archived on \(when) to \(volume)\(via)", verified: true)
        }
        return ArchivedBanner(text: "In the archive on \(volume)\(via) — not yet verified", verified: false)
    }

    @ViewBuilder
    private func inspectorRow(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .trailing)
                Text(value)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func inspectorCopyableRow(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .trailing)
                Text(value)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
            }
        }
    }

    private func streamTypeColor(_ st: StreamType) -> Color {
        switch st {
        case .videoOnly:     return .orange
        case .audioOnly:     return .yellow
        case .ffprobeFailed: return .red
        default:             return .primary
        }
    }

    // MARK: - Duplicate Copy Row

    @ViewBuilder
    private func duplicateCopyRow(
        filename: String,
        volumeName: String,
        directory: String,
        disposition: DuplicateDisposition,
        isSameVolume: Bool,
        isSelected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle()
                    .fill(disposition.textColor)
                    .frame(width: 6, height: 6)
                Text(filename)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isSelected {
                    Text("(selected)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 4) {
                Image(systemName: isSameVolume ? "internaldrive" : "externaldrive")
                    .font(.system(size: 9))
                    .foregroundColor(isSameVolume ? .secondary : .orange)
                Text(volumeName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isSameVolume ? .secondary : .orange)
                if !isSameVolume {
                    Text("(different volume)")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                }
            }
            Text(directory)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
    }
}

// MARK: - Star Rating View

struct StarRatingView: View {
    @Binding var rating: Int
    /// Fired after a tap changes the rating — hosts hang persistence here
    /// (`model.saveCatalogDebounced()`). Defaulted so previews stay simple.
    var onCommit: () -> Void = {}
    let maxStars: Int = 3

    /// Local mirror of the bound value (Rick 2026-08-19: "the stars don't
    /// turn on — sometimes they do"). `VideoRecord` is a plain class, so
    /// writing `rec.starRating` through the binding never invalidates the
    /// host view — the control repainted only when something ELSE
    /// re-rendered it. The tap drives THIS @State (always repaints), and
    /// the binding write follows for the model.
    @State private var shown: Int = 0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...maxStars, id: \.self) { star in
                Image(systemName: star <= shown ? "star.fill" : "star")
                    .font(.system(size: 14))
                    .foregroundColor(star <= shown ? .yellow : .secondary.opacity(0.4))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let new = (shown == star) ? 0 : star
                        shown = new
                        rating = new
                        onCommit()
                    }
                    .accessibilityIdentifier("starRating.\(star)")
            }
        }
        .onAppear { shown = rating }
        // Row reuse / selection change / external edits (Promote sets ★★★):
        // the bound value re-reads each render; follow it when it moves.
        .onChange(of: rating) { _, new in shown = new }
    }
}
