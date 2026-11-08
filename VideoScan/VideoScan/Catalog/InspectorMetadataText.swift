// InspectorMetadataText.swift
// "Copy All Metadata" as plain text: one formatter per inspector section,
// listed once, in the order the copied text shows them. Split out of
// InspectorPanel.formatAllMetadata (C → B lift, 2026-11-07) — same text
// byte for byte (InspectorMetadataTextCharacterizationTests), no new facts.
//
// Pure: a record plus the related records the CALLER already resolved
// (duplicate group, same footage) in, text out. No I/O beyond the volume
// label / reachability lookups the old code made, nothing O(records).
// C++ analogy: a value-type builder that owns a std::vector<std::string>;
// each section is a member function that appends to it.

import Foundation

@MainActor
struct InspectorMetadataText {

    /// Records related to the one being copied, resolved and memoized by
    /// the caller (InspectorPanelRules) — never searched for here.
    struct Related {
        var duplicateGroup: [VideoRecord] = []
        var sameFootage: [VideoRecord] = []
        var possibleSameFootage: [VideoRecord] = []
    }

    private(set) var lines: [String] = []
    var text: String { lines.joined(separator: "\n") }

    /// The whole copy, section by section. The order here IS the order of
    /// the copied text; each section decides its own visibility.
    static func format(_ rec: VideoRecord, related: Related = Related()) -> String {
        var t = InspectorMetadataText()
        t.header(rec)
        t.general(rec)
        t.video(rec)
        t.audio(rec)
        t.timestamps(rec)
        t.correlation(rec)
        t.duplicates(rec, related)
        t.avidProject(rec)
        t.notes(rec)
        t.dossier(rec)
        t.location(rec)
        return t.text
    }

    // MARK: - Line primitives

    /// "  Label: value"; an empty value is not a fact, so no line.
    mutating func add(_ label: String, _ value: String) {
        guard !value.isEmpty else { return }
        lines.append("  \(label): \(value)")
    }

    /// "[Title]", separated from what came before by one blank line.
    mutating func section(_ title: String) {
        if !lines.isEmpty { lines.append("") }
        lines.append("[\(title)]")
    }

    mutating func line(_ text: String) {
        lines.append(text)
    }

    // MARK: - Sections, top to bottom

    /// The filename, then the facts that identify the file at a glance.
    mutating func header(_ rec: VideoRecord) {
        line(rec.filename)
        line("  Stream Type: \(CatalogFileFacts.stream(rec).help)")
        line("  Volume: \(VolumeReachability.displayLabel(forPath: rec.fullPath))")
        if rec.starRating > 0 {
            line("  Rating: \(String(repeating: "★", count: rec.starRating))")
        }
        if !rec.tags.isEmpty {
            line("  Tags: \(rec.tags.joined(separator: ", "))")
        }
        if rec.hasAvidMetadata {
            add("Tape", rec.avidTapeName)
            add("Clip", rec.avidClipName)
        }
    }

    mutating func general(_ rec: VideoRecord) {
        section("General")
        add("Size", rec.size)
        add("Duration", rec.duration)
        add("Container", rec.container)
        add("Extension", rec.ext)
    }

    mutating func video(_ rec: VideoRecord) {
        section("Video")
        add("Resolution", rec.resolution)
        add("Codec", rec.videoCodec)
        add("Frame Rate", rec.frameRate)
        add("Bitrate", rec.videoBitrate)
        add("Total Bitrate", rec.totalBitrate)
        add("Color Space", rec.colorSpace)
        add("Bit Depth", rec.bitDepth)
        add("Scan Type", rec.scanType)
    }

    mutating func audio(_ rec: VideoRecord) {
        section("Audio")
        add("Codec", rec.audioCodec)
        add("Channels", rec.audioChannels)
        add("Sample Rate", rec.audioSampleRate)
    }

    mutating func timestamps(_ rec: VideoRecord) {
        section("Timestamps")
        add("Your Date", Self.yourDate(rec) ?? "")
        add("Embedded", Self.embeddedDate(rec) ?? "")
        add("Origin", rec.originDescription ?? "")
        add("Created", rec.dateCreated)
        add("Modified", rec.dateModified)
        add("Timecode", rec.timecode)
        add("Tape Name", rec.tapeName)
    }

    /// Only when the file is paired or was scored for a pair.
    mutating func correlation(_ rec: VideoRecord) {
        guard rec.pairedWith != nil || rec.pairConfidence != nil else { return }
        section("Correlation")
        if let paired = rec.pairedWith {
            add("Paired With", paired.filename)
            add("Pair Volume", VolumeReachability.displayLabel(forPath: paired.fullPath))
            add("Pair Path", paired.fullPath)
        }
        add("Confidence", rec.pairConfidence?.rawValue ?? "")
    }

    /// Same footage (sure, then possible) and, for duplicate-flagged files,
    /// the verdict and the group listing.
    mutating func duplicates(_ rec: VideoRecord, _ related: Related) {
        let footage = related.sameFootage + related.possibleSameFootage
        guard InspectorPanelRules.showsDuplicatesOrSameFootage(rec, sameFootage: footage) else { return }
        section("Duplicates")
        for other in related.sameFootage {
            add("Same footage as", InspectorPanelRules.sameFootageLine(other))
        }
        for other in related.possibleSameFootage {
            add("Same footage as (possible)", InspectorPanelRules.sameFootageLine(other))
        }
        guard InspectorPanelRules.showsDuplicates(rec) else { return }
        if rec.duplicateDisposition != .none {
            add("Status", InspectorPanelRules.duplicateStatusText(rec))
        }
        add("Reasons", rec.duplicateReasons)
        add("Confidence", rec.duplicateConfidence?.rawValue ?? "")
        duplicateGroup(rec, related.duplicateGroup)
    }

    /// "Duplicate Group (N total):" — this file starred, then each member
    /// with its volume, an (offline) mark, and its disposition.
    mutating func duplicateGroup(_ rec: VideoRecord, _ members: [VideoRecord]) {
        guard !members.isEmpty else { return }
        line("")
        line("  Duplicate Group (\(members.count + 1) total):")
        let thisVol = VolumeReachability.volumeName(forPath: rec.fullPath)
        line("    ★ \(rec.filename)  [\(thisVol)]  \(rec.duplicateDisposition.rawValue)")
        for member in members {
            let vol = VolumeReachability.volumeName(forPath: member.fullPath)
            let offline = VolumeReachability.isReachable(path: member.fullPath) ? "" : " (offline)"
            line("    · \(member.filename)  [\(vol)]\(offline)  \(member.duplicateDisposition.rawValue)")
        }
    }

    mutating func avidProject(_ rec: VideoRecord) {
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

    /// Your notes first, then the machine / probe notes; each only when
    /// non-empty, as one indented block.
    mutating func notes(_ rec: VideoRecord) {
        if !rec.userNotes.isEmpty {
            section("Your Notes")
            line("  \(rec.userNotes)")
        }
        if !rec.notes.isEmpty {
            section("Notes")
            line("  \(rec.notes)")
        }
    }

    /// Scene captions, transcript, OCR — the most copy-worthy fields once a
    /// file is dossier'd (Rick 2026-06-09). Omitted when there is nothing.
    /// GH #402: an OCR date the verdict calls degenerate is never quoted.
    mutating func dossier(_ rec: VideoRecord) {
        let ocrDates = rec.usableOCRDates
        guard Self.hasDossierContent(rec, usableOCRDates: ocrDates) else { return }
        section("Dossier")
        if let inferred = Self.inferredDate(rec) { line("  Inferred Record Date: \(inferred)") }
        if let processed = Self.processed(rec) { line("  Processed: \(processed)") }
        timedList("Scene Captions", rec.sceneCaptions)
        transcript(rec.audioTranscript ?? "")
        timedList("OCR Text", rec.ocrText)
        timedList("OCR Date Candidates", ocrDates)
    }

    mutating func location(_ rec: VideoRecord) {
        section("Location")
        add("Path", rec.fullPath)
        add("Directory", rec.directory)
        add("MD5 (partial)", rec.partialMD5)
        add("File Signature", rec.contentHashDisplay)
    }

    // MARK: - Dossier blocks

    /// "  Heading (N):" then "    [m:ss] text" per item; nothing when empty.
    mutating func timedList(_ heading: String, _ items: [SceneCaption]) {
        guard !items.isEmpty else { return }
        line("")
        line("  \(heading) (\(items.count)):")
        for item in items {
            line("    [\(Self.clock(item.timestamp))] \(item.text)")
        }
    }

    /// The transcript as one block, every line (blank ones too) indented 4,
    /// so it pastes elsewhere with its natural flow.
    mutating func transcript(_ text: String) {
        guard !text.isEmpty else { return }
        line("")
        line("  Audio Transcript:")
        for textLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            line("    \(textLine)")
        }
    }

    // MARK: - Values (pure)

    /// "1992-07-15 (known)" / "1992 (best guess)"; nil without a date.
    static func yourDate(_ rec: VideoRecord) -> String? {
        guard let userDate = rec.userDate else { return nil }
        return rec.userDateStatus == .known ? "\(userDate) (known)" : "\(userDate) (best guess)"
    }

    /// The embedded creation instant in UTC, with its source tag if known.
    static func embeddedDate(_ rec: VideoRecord) -> String? {
        guard let embedded = rec.embeddedCreationDate else { return nil }
        let source = rec.embeddedCreationSource.map { " (\($0))" } ?? ""
        return InspectorDateView.embeddedFormatter.string(from: embedded) + " UTC" + source
    }

    static func hasDossierContent(_ rec: VideoRecord, usableOCRDates: [SceneCaption]) -> Bool {
        !rec.sceneCaptions.isEmpty
            || !(rec.audioTranscript ?? "").isEmpty
            || !rec.ocrText.isEmpty
            || !usableOCRDates.isEmpty
            || rec.inferredRecordDate != nil
    }

    /// GH #293: a year-only inference is copied as its year, a day-precise
    /// one as a medium date; then the confidence when there is one.
    static func inferredDate(_ rec: VideoRecord) -> String? {
        guard let inferred = rec.inferredRecordDate else { return nil }
        let shown = rec.effectiveInferredDateRange?.displayString ?? mediumDate(inferred)
        guard let conf = rec.inferredDateConfidence else { return shown }
        return shown + " (confidence \(String(format: "%.2f", conf)))"
    }

    /// "Qwen2.5-VL on 9/21/26, 10:13 AM"; nil unless both who and when are known.
    static func processed(_ rec: VideoRecord) -> String? {
        guard let by = rec.dossierProcessedBy, !by.isEmpty,
              let at = rec.dossierProcessedAt else { return nil }
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        return "\(by) on \(fmt.string(from: at))"
    }

    static func mediumDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt.string(from: date)
    }

    /// m:ss, the inspector dossier's timestamp form (negative clamps to 0).
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
