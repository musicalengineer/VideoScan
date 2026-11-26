// FileJourneyBuilder.swift
// Builds the File Journey sheet's one value (Rick 2026-11-14): the ladder's
// evidence, the timeline, and the detail sections under it.
//
// THE FOOTAGE, NOT THE ROW. A catalog row is one copy. The sheet is about the
// footage, so the builder reads a small FAMILY together: the row it was
// opened on, the archived copy of it, and that copy's source. Opening the
// sheet on the archive copy itself used to read "not archived" — the old
// ladder only looked for ANOTHER row that was this one's copy.
//
// EVERY LINE FROM A DATED FIELD. The timeline states only what a record
// carries with a date: the file's own clock, an analyzer's stamp, a person's
// confirmed tag, the archive copy's promote date, a read-back's date, and one
// stat of each path made here, once. Machine notes (ffprobe text) and history
// lines whose date cannot be read are not events; they go to Technical notes.
//
// Pure over what it is handed: no store, no catalog read, no ledger (the ledger
// is a whole-file read — not for sheet open). The model's wrapper passes the
// proven copy, the estimates and the archive's name. The only I/O is `probe`
// (lstat/stat), injected for tests.
//
// (For Rick: an `enum` with only static functions is a namespace, like a C++
// namespace of free functions; `@MainActor` pins it to the UI thread because
// VideoRecord lives there.)

import Foundation

@MainActor
enum FileJourneyBuilder {

    /// What the caller knows that the records do not carry.
    struct Extras {
        /// The dossier Analysis Scope (which streams the batch analyzes).
        var analysisScope = AnalysisScope()
        /// The archive's root folder: a file under it is in the archive.
        var archiveRootPath: String?
        /// What to call the archive ("FamilyArchive"); nil = its volume's name.
        var archiveName: String?
        /// The person confirmed the estimated provenance of this footage.
        var provenanceConfirmed = false
        /// A path with every link in it resolved (realpath), nil when the
        /// disk will not say. Injectable for tests.
        var resolvePath: (String) -> String? = FileJourneyBuilder.realPath
        var now = Date()
    }

    // MARK: - Build

    static func build(for rec: VideoRecord,
                      allRecords: [VideoRecord],
                      resolveVolumeSafety: VolumeSafetyResolver,
                      archivedCopy: VideoRecord?,
                      provenance: JourneyProvenance?,
                      machineEra: JourneyMachineEra?,
                      extras: Extras,
                      probe: (String) -> JourneyPresence) -> FileJourney {
        let family = Family(rec: rec, archivedCopy: archivedCopy, allRecords: allRecords, extras: extras)
        // Each path is asked of the disk ONCE; the answers feed both the
        // ladder and the last event, so the two cannot disagree.
        let recPresence = probe(rec.fullPath)
        var copyPresence: JourneyPresence? = family.copy.map { $0.id == rec.id ? recPresence : probe($0.fullPath) }
        // A regular file whose REAL location is outside the archive's real
        // folder was reached through a link, whatever disk it is on (Codex #293 F1).
        if let copy = family.copy, copyPresence == .regularFile, let root = extras.archiveRootPath,
           escapesArchive(copy.fullPath, root: root, resolve: extras.resolvePath) {
            copyPresence = .regularFileThroughLink(at: root)
        }
        let place = archivePlace(family.copy, extras: extras)
        let notes = NoteLines(rec: rec, copy: family.copy, now: extras.now)

        let evidence = PreservationEvidence(
            catalogued: catalogued(family, notes: notes, now: extras.now),
            analysis: analysis(family, scope: extras.analysisScope, catalog: allRecords, now: extras.now),
            review: review(family, notes: notes, extras: extras),
            archive: archiveStanding(family.copy, presence: copyPresence, place: place, now: extras.now),
            offsite: offsite(family))

        var events: [JourneyEvent] = []
        if let event = cataloguedEvent(evidence.catalogued) { events.append(event) }
        if let provenance {
            events.append(event(.provenance, at: provenance.captured, provenance.sentence))
        }
        if let machineEra {
            events.append(event(.machineEstimate, at: machineEra.observed, machineEra.sentence))
        }
        events += analysisEvents(family, now: extras.now)
        events += reviewEvents(family, notes: notes, allRecords: allRecords, now: extras.now)
        events += archiveEvents(family, place: place, presence: copyPresence, extras: extras)
        events += notes.events
        // A date from before the app existed, or from the future, dates nothing
        // (Codex #292 F6): the event is not shown rather than shown at a false time.
        // (The provenance line is dated at the footage's CAPTURE — 1994 is a fine capture year.)
        events.removeAll { event in
            event.kind != .provenance && (event.timestamp.map { real($0, now: extras.now) == nil } ?? false)
        }

        let isMarkedDeleted = rec.archiveStage == .manuallyDeleted
        var ordered = [originEvent(for: rec)] + sorted(events)
        ordered.append(currentStateEvent(for: rec, family: family, recPresence: recPresence,
                                         copyPresence: copyPresence, isMarkedDeleted: isMarkedDeleted,
                                         now: extras.now, probe: probe))

        return FileJourney(
            recordID: rec.id,
            filename: rec.filename,
            isMarkedDeleted: isMarkedDeleted,
            events: ordered,
            otherKnownCopies: VideoScanModel.knownCopies(of: rec, allRecords: allRecords,
                                                         resolveVolumeSafety: resolveVolumeSafety),
            preservation: PreservationChecklist.steps(from: evidence),
            details: details(for: rec, technicalNotes: notes.technical))
    }

    // MARK: - The family (row, archived copy, the copy's source)

    @MainActor
    struct Family {
        let rec: VideoRecord
        /// The copy in the archive: the row itself when it is one, else the
        /// proven copy the caller resolved, else the promote link's.
        let copy: VideoRecord?
        /// The row the archive copy was promoted from, when `rec` is the copy.
        let source: VideoRecord?
        /// `rec` first, then the others, each once.
        let members: [VideoRecord]

        init(rec: VideoRecord, archivedCopy: VideoRecord?, allRecords: [VideoRecord], extras: Extras) {
            self.rec = rec
            let isPromotedCopy = rec.derivationKind == ArchivePromotion.derivationKind
            let inArchive = FileJourneyBuilder.isInArchive(rec.fullPath, root: extras.archiveRootPath)
            if isPromotedCopy || inArchive {
                // A purged row is not a copy of anything, opened directly or not (Codex #292 F2).
                copy = rec.isPurged ? nil : rec
            } else {
                let candidate = archivedCopy ?? allRecords.first {
                    $0.derivedFrom == rec.id && $0.derivationKind == ArchivePromotion.derivationKind
                }
                // The promote link says what the copy was MADE from, not what
                // the row holds today: bytes that differ are other footage, and
                // the archive does not hold this row's (Codex #292 F3).
                copy = candidate.flatMap { !$0.isPurged && FileJourneyBuilder.sameFootage(rec, $0) ? $0 : nil }
            }
            let sourceID = isPromotedCopy ? rec.derivedFrom : nil
            source = sourceID.flatMap { id in allRecords.first { $0.id == id } }
                .flatMap { FileJourneyBuilder.sameFootage(rec, $0) ? $0 : nil }
            var all = [rec]
            for other in [copy, source].compactMap({ $0 }) where !all.contains(where: { $0.id == other.id }) {
                all.append(other)
            }
            members = all
        }

        /// The first member (the row first) that answers.
        func first<T>(_ read: (VideoRecord) -> T?) -> T? {
            for member in members { if let value = read(member) { return value } }
            return nil
        }
    }

    /// Are two rows the same footage, as far as the catalog can tell? Both
    /// whole-file hashes known: they must be equal. Otherwise the promote
    /// link stands unless the sizes already differ. (A row is itself.)
    static func sameFootage(_ a: VideoRecord, _ b: VideoRecord) -> Bool {
        if a.id == b.id { return true }
        // A row whose own two hashes disagree is known to be in doubt: it is
        // the same footage as nothing until it is verified (Codex #293 F2).
        if contradictsItself(a) || contradictsItself(b) { return false }
        if let left = ArchivePromotionIndex.verifiedDigest(of: a), let right = ArchivePromotionIndex.verifiedDigest(of: b) {
            return left == right
        }
        return a.sizeBytes == b.sizeBytes
    }

    /// Both whole-file hashes on record, and they differ: the archive fixity
    /// says one thing and a later full read of the file says another.
    static func contradictsItself(_ r: VideoRecord) -> Bool {
        guard let archive = r.archiveFixity, archive.algorithm == ContentFixity.sha256, ArchiveDigestIndex.isSHA256(archive.digest),
              let content = r.contentFixity, content.algorithm == ContentFixity.sha256, ArchiveDigestIndex.isSHA256(content.digest)
        else { return false }
        return archive.digest.lowercased() != content.digest.lowercased()
    }

    /// realpath(3): every link resolved. nil when nothing is there to resolve.
    nonisolated static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The path reads as inside the archive, and its real location is not.
    /// When the disk will not resolve either path, nothing is concluded.
    static func escapesArchive(_ path: String, root: String, resolve: (String) -> String?) -> Bool {
        guard isInArchive(path, root: root), let real = resolve(path), let realRoot = resolve(root) else { return false }
        return !isInArchive(real, root: realRoot)
    }

    /// A date the app could have written: 2000-01-01 … now. Anything else
    /// (the 1970 loader default, a clock set wrong, a poisoned row) is not
    /// evidence of when something happened — or that it happened.
    static func real(_ date: Date?, now: Date) -> Date? {
        guard let date, date <= now, date.timeIntervalSince1970 >= 946_684_800 else { return nil }
        return date
    }

    // MARK: - Catalogued

    /// The earliest date the catalog holds for the footage. The first day
    /// itself was never recorded (`files.catalogued_at` is NULL), so this is
    /// a bound and is said to be one — `isExact` false.
    static func catalogued(_ family: Family, notes: NoteLines, now: Date) -> JourneyCatalogued {
        let dates = (family.members.flatMap(appDates) + notes.stamps).compactMap { real($0, now: now) }
        return JourneyCatalogued(date: dates.min(), isExact: false)
    }

    /// Every date the APP wrote on this record (never the file's own clock).
    static func appDates(_ r: VideoRecord) -> [Date] {
        var out: [Date?] = [
            r.scanContext.scannedAt, r.contentHashAt, r.contentFixity?.computedAt,
            r.archivedAt, r.archiveFixity?.verifiedAt,
            r.sceneCaptionDate, r.audioTranscriptDate, r.dossierProcessedAt,
            r.audioVerifyDate, r.videoVerifyDate, r.dupAnalyzedAt,
            r.mediaReportCard?.checkedAt, r.footage?.scannedAt, r.repairConfirmedDate,
        ]
        out += r.confirmedByUserPeople.map { Optional($0.confirmedAt) }
        out += r.footageDecisions.map { Optional($0.decidedAt) }
        return out.compactMap { $0 }
    }

    static func cataloguedEvent(_ c: JourneyCatalogued) -> JourneyEvent? {
        guard let date = c.date else { return nil }
        let sentence = c.isExact
            ? "Catalogued by VideoScan."
            : "Catalogued by VideoScan. The first day was not recorded — this is the earliest date the catalog holds for this footage."
        let stamp = (c.isExact ? "" : "On or before ") + friendlyDay(date)
        return JourneyEvent(timestamp: date, displayStamp: stamp, icon: JourneyEventKind.catalogued.defaultIcon,
                            kind: .catalogued, sentence: sentence)
    }

    // MARK: - Analyzed

    /// The content analyzers over the family, by Catalog Status's own
    /// per-file rule: an analyzer applies when it applies to any copy, and
    /// has run when any copy carries its stamp (the copies are one footage).
    static func analysis(_ family: Family, scope: AnalysisScope, catalog: [VideoRecord]? = nil,
                         now: Date = Date()) -> JourneyAnalysis {
        var applies: [AnalyzeCycler: Bool] = [:]
        var covered: [AnalyzeCycler: Bool] = [:]
        var at: [AnalyzeCycler: Date] = [:]
        // Bytes ANY copy in the catalog proved undecodable are undecodable in
        // every copy — the batch skips them, so nothing is "in the queue" for
        // them. The whole catalog, as Catalog Status builds it (Codex #292 F9):
        // one pass, at sheet open.
        let unreadable = UnreadableContentIndex(records: catalog ?? family.members)
        for member in family.members {
            let input = AnalyzeCoverageInput(record: member, unreadable: unreadable)
            let dossier = AnalyzeDossierVerdict(input, scope: scope)
            AnalyzeCoverageCalculator.forEachContentAnalyzer(input, dossier: dossier) { cycler, isFor, has, stamp, _ in
                if isFor { applies[cycler] = true }
                guard has else { return }
                covered[cycler] = true
                if let when = real(stamp ?? stampDate(cycler, member), now: now), at[cycler].map({ when < $0 }) ?? true {
                    at[cycler] = when
                }
            }
        }
        let items = AnalyzeCoverageReport.contentAnalyzers
            .filter { applies[$0] == true }
            .map { JourneyAnalysisItem(title: passTitle($0), covered: covered[$0] == true, at: at[$0]) }
        return JourneyAnalysis(items: items)
    }

    /// The record's own date for an analyzer's stamp, where it keeps one.
    static func stampDate(_ cycler: AnalyzeCycler, _ r: VideoRecord) -> Date? {
        switch cycler {
        case .duplicates:     return r.dupAnalyzedAt
        case .sceneCaptions:  return r.sceneCaptionDate ?? r.dossierProcessedAt
        case .ocr:            return r.dossierProcessedAt
        case .transcribe:     return r.audioTranscriptDate ?? r.dossierProcessedAt
        case .fileSignatures: return r.contentHashAt
        default:              return nil
        }
    }

    /// The pass in plain words (the Analyze panel's titles are verbs for a row of buttons).
    static func passTitle(_ cycler: AnalyzeCycler) -> String {
        switch cycler {
        case .fullHashes:     return "whole-file fingerprint"
        case .soundPrints:    return "sound print"
        case .duplicates:     return "duplicate check"
        case .sceneCaptions:  return "scene descriptions"
        case .ocr:            return "on-screen text"
        case .transcribe:     return "speech transcript"
        case .fileSignatures: return "quick signature"
        default:              return cycler.menuTitle.lowercased()
        }
    }

    /// The machine passes that left a dated result worth a line.
    static func analysisEvents(_ family: Family, now: Date = Date()) -> [JourneyEvent] {
        var out: [JourneyEvent] = []
        // The first family member with a REAL date answers: an impossible one
        // on the opened row never hides its other copy's (Codex #293 F6).
        func ok(_ date: Date?) -> Date? { real(date, now: now) }
        if let (at, count) = family.first({ r in ok(r.sceneCaptionDate).map { ($0, r.sceneCaptions.count) } }) {
            out.append(event(.analysis, at: at, count == 0
                ? "The machine looked for scenes to describe and found none."
                : "The machine described \(count) scene\(count == 1 ? "" : "s")."))
        }
        if let (at, text) = family.first({ r in ok(r.audioTranscriptDate).map { ($0, r.audioTranscript ?? "") } }) {
            out.append(event(.analysis, at: at, text.isEmpty
                ? "The machine listened for speech and heard none."
                : "The machine transcribed the speech."))
        }
        if let (at, status, note) = family.first({ r in
            r.audioVerifyStatus.isEmpty ? nil : ok(r.audioVerifyDate).map { ($0, r.audioVerifyStatus, r.audioVerifyNote) }
        }) {
            out.append(event(.analysis, at: at, verifyWords("Sound check", status: status, note: note)))
        }
        if let (at, status, note) = family.first({ r in
            r.videoVerifyStatus.isEmpty ? nil : ok(r.videoVerifyDate).map { ($0, r.videoVerifyStatus, r.videoVerifyNote) }
        }) {
            out.append(event(.analysis, at: at, verifyWords("Picture check", status: status, note: note)))
        }
        if let card = family.first({ r in r.mediaReportCard.flatMap { ok($0.checkedAt) == nil ? nil : $0 } }) {
            // "Media check", not the retired menu verb (it is "Verify…" since 2026-10-08).
            out.append(event(.analysis, at: card.checkedAt, "Media check (\(card.tier.rawValue)): \(card.headline)"))
        }
        return out
    }

    /// "Sound check: ok." / "Sound check: damaged — <the check's own note>."
    static func verifyWords(_ name: String, status: String, note: String) -> String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return status == "ok" || trimmed.isEmpty ? "\(name): \(status)." : "\(name): \(status) — \(trimmed)"
    }

    // MARK: - Reviewed

    /// The person's own acts on the footage. Star rating, classification and
    /// `archiveStage` are NOT here: Promote and the analyzers write them.
    static func review(_ family: Family, notes: NoteLines, extras: Extras) -> JourneyReview {
        var acts: [String] = []
        var dates: [Date] = []
        if family.members.contains(where: pfRecordHasConfirmedDate) { acts.append("date set") }
        if family.members.contains(where: { $0.userPlaceStatus != .unplaced }) { acts.append("place set") }
        let people = Set(family.members.flatMap { $0.confirmedByUserPeople.map(\.name) })
        if !people.isEmpty {
            acts.append("\(people.count) \(people.count == 1 ? "person" : "people") confirmed")
            dates += family.members.flatMap { $0.confirmedByUserPeople.map(\.confirmedAt) }
        }
        if family.members.contains(where: { !humanNote($0).isEmpty }) { acts.append("note") }
        let decisions = family.members.flatMap(\.footageDecisions)
        if !decisions.isEmpty {
            acts.append("same-footage answer")
            dates += decisions.map(\.decidedAt)
        }
        // The date IS the record of this act: one that cannot be real records nothing.
        if let repaired = family.first({ real($0.repairConfirmedDate, now: extras.now) }) {
            acts.append("repair confirmed")
            dates.append(repaired)
        }
        if !notes.updates.isEmpty {
            acts.append("archived file updated")
            dates += notes.updates.compactMap(\.at)
        }
        if extras.provenanceConfirmed { acts.append("provenance confirmed") }
        return JourneyReview(acts: acts, latest: dates.compactMap { real($0, now: extras.now) }.max())
    }

    /// The dated ones, as timeline lines.
    static func reviewEvents(_ family: Family, notes: NoteLines, allRecords: [VideoRecord],
                             now: Date = Date()) -> [JourneyEvent] {
        var out: [JourneyEvent] = []
        // People confirmed on one day read as one line.
        var byDay: [Date: (at: Date, names: [String])] = [:]
        for tag in family.members.flatMap(\.confirmedByUserPeople) {
            let day = Calendar.current.startOfDay(for: tag.confirmedAt)
            var entry = byDay[day] ?? (tag.confirmedAt, [])
            if !entry.names.contains(tag.name) { entry.names.append(tag.name) }
            entry.at = min(entry.at, tag.confirmedAt)
            byDay[day] = entry
        }
        for entry in byDay.values {
            let names = ListFormatter.localizedString(byJoining: entry.names.sorted())
            out.append(event(.review, at: entry.at, "You confirmed \(names) \(entry.names.count == 1 ? "is" : "are") in this."))
        }
        var seenPairs = Set<UUID>()
        // The date is checked BEFORE the pair is used up, so an impossible
        // answer never hides a real one about the same file (Codex #294 F2).
        for decision in family.members.flatMap(\.footageDecisions)
        where real(decision.decidedAt, now: now) != nil && seenPairs.insert(decision.otherID).inserted {
            let other = allRecords.first { $0.id == decision.otherID }?.filename ?? "another file"
            out.append(event(.review, at: decision.decidedAt, decision.verdict == .same
                ? "You said this is the same footage as \(other)."
                : "You said this is not the same footage as \(other)."))
        }
        if let repaired = family.first({ real($0.repairConfirmedDate, now: now) }) {
            out.append(event(.review, at: repaired, "You confirmed the repaired copy."))
        }
        for update in notes.updates {
            out.append(event(.review, at: update.at, "You updated the archived file — \(update.reason)."))
        }
        return out
    }

    // MARK: - Archived

    /// What to call where the copy is: the caller's name, else the volume's.
    static func archivePlace(_ copy: VideoRecord?, extras: Extras) -> String {
        // The archive's own name only for a copy inside it: a promoted copy
        // left under an earlier root is named by where it is.
        let insideCurrent = copy.map { isInArchive($0.fullPath, root: extras.archiveRootPath) } ?? true
        if insideCurrent || extras.archiveRootPath == nil, let name = extras.archiveName, !name.isEmpty { return name }
        guard let copy, copy.fullPath.hasPrefix("/Volumes/") else { return "the archive" }
        return JourneyPresence.volumeName(copy.fullPath)
    }

    /// Ticked only for a copy that is ON DISK (the stat's answer) and known
    /// by a whole-file SHA-256. Otherwise the reason is the to-do.
    static func archiveStanding(_ copy: VideoRecord?, presence: JourneyPresence?, place: String,
                                now: Date = Date()) -> JourneyArchiveStanding {
        guard let copy, !copy.isPurged else { return .notArchived }
        guard let presence, presence.isPresent else { return .unproven(todo: copyNotOnDiskTodo(presence)) }
        // The bytes themselves, at that path: a link — or a folder link onto
        // another disk — means they are somewhere else, and removing THAT file
        // removes "the archive copy" (Codex #292 F1).
        guard presence == .regularFile else { return .unproven(todo: linkTodo) }
        guard !contradictsItself(copy) else { return .unproven(todo: contradictionTodo) }
        guard ArchivePromotionIndex.verifiedDigest(of: copy) != nil else {
            return .unproven(todo: "Run Verify Archive — no whole-file check (SHA-256) is recorded for the archived copy.")
        }
        return .archived(place: place, at: real(archiveDay(copy), now: now),
                         checkedAt: archiveProof(copy) == .readBack ? real(copy.archiveFixity?.verifiedAt, now: now) : nil)
    }

    static let contradictionTodo = "The archived copy's two whole-file hashes disagree — run Verify Archive before trusting it."

    static let linkTodo = "The archived copy's path is a link, not the file itself — the archive does not hold these bytes. Run Verify Archive."

    /// The day Promote archived it: its own stamp, else the copy's promote
    /// note. NEVER the fixity's date — that moves with every Verify, and a
    /// check is not the day it was archived (`resolvedArchivedAt` follows the
    /// same rule since GH #477).
    static func archiveDay(_ copy: VideoRecord) -> Date? {
        copy.archivedAt ?? VideoRecord.promoteStamp(inNotes: copy.notes)
    }

    /// How the copy's bytes are known. A copy Promote made was READ BACK and
    /// compared (its archive fixity); any other file in the archive has at
    /// most a fingerprint of itself — nothing was compared to anything.
    enum ArchiveProof { case readBack, fingerprintOnly, contradictory, none }

    static func archiveProof(_ copy: VideoRecord) -> ArchiveProof {
        if contradictsItself(copy) { return .contradictory }
        guard ArchivePromotionIndex.verifiedDigest(of: copy) != nil else { return .none }
        let promoted = copy.derivationKind == ArchivePromotion.derivationKind
        // The ARCHIVE fixity itself must be a whole-file SHA-256: a malformed
        // one beside a valid fingerprint is a fingerprint (Codex #292 F4).
        let readBack = copy.archiveFixity.map { $0.algorithm == ContentFixity.sha256 && ArchiveDigestIndex.isSHA256($0.digest) } ?? false
        return promoted && readBack ? .readBack : .fingerprintOnly
    }

    /// One rule for "inside the archive": the model's own.
    static func isInArchive(_ path: String, root: String?) -> Bool {
        VideoScanModel.isInsideMasterArchive(path: path, root: root)
    }

    /// The person's own lines of `userNotes` — machine text that once leaked
    /// in there (GH #176) is not theirs.
    static func humanNote(_ r: VideoRecord) -> String {
        // The one classifier is Core's MachineNote; the Archive Angel's view of
        // it is the Angel's own (ArchiveAngelBoundarySensorTests: code outside
        // ArchiveAngel/ names only its public surface).
        r.userNotes.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !MachineNote.isMachineLine($0) }
            .joined(separator: "\n")
    }

    /// The copy record exists but its file was not seen: unplugged,
    /// unreadable, or not there.
    static func copyNotOnDiskTodo(_ presence: JourneyPresence?) -> String {
        switch presence {
        case .volumeOffline(let volume)?:
            return "Connect \(volume) — the archived copy could not be checked."
        case .unknown(let reason)?, .linkTargetUnknown(_, let reason)?:
            return "The archived copy could not be checked (\(reason)) — then run Verify Archive."
        case nil:
            return "Run Verify Archive — the archived copy has not been checked on disk."
        default:
            return "Run Verify Archive — the archived copy is not at its path."
        }
    }

    /// "Archived to FamilyArchive as …" from the COPY RECORD (its date, its
    /// digest), never the note string; then a later read-back, if there was one.
    static func archiveEvents(_ family: Family, place: String, presence: JourneyPresence?,
                              extras: Extras) -> [JourneyEvent] {
        guard let copy = family.copy else { return [] }
        let at = real(archiveDay(copy), now: extras.now)
        let promoted = copy.derivationKind == ArchivePromotion.derivationKind
        // "Archived to" is Promote's act, and stays true as history. A file
        // that is simply in the archive's folder is said to be THERE — a
        // statement about now, made only when the disk agrees (Codex #292 F7).
        if !promoted, presence != .regularFile { return [] }
        var sentence = "\(promoted ? "Archived to" : "In") \(place) as \(archiveRelativePath(copy, root: extras.archiveRootPath))."
        // Where Promote copied it from: what Promote itself RECORDED — on the
        // copy, else in the copy's promote note. Never a row's present path,
        // which Migrate moves (Codex #292 F8); with no record, nothing is said.
        // Left out when the first line of the timeline already names it.
        let foundAt = family.rec.originalFullPath ?? family.rec.fullPath
        // The note is Promote's own line; `originalFullPath` can be Migrate's
        // (it fills a missing one with the moving row's former path), so the
        // note outranks it and a path inside the archive is never a source
        // (Codex #293 F4).
        if promoted, let from = promoteSource(of: copy), from != copy.fullPath, from != foundAt,
           !isInArchive(from, root: extras.archiveRootPath) {
            sentence += " Copied from \(from)."
        }
        switch archiveProof(copy) {
        case .readBack:        sentence += " The copy was read back and matched, bit for bit."
        case .fingerprintOnly: sentence += " A whole-file fingerprint is recorded for it."
        case .contradictory:   sentence += " Its two whole-file hashes now disagree."
        case .none:            sentence += " No whole-file check is recorded for the copy."
        }
        if let readiness = readinessWords(inNotes: copy.notes) {
            sentence += " Checked before archiving: \(readiness)."
        }
        var out = [event(.archived, at: at, sentence)]
        if archiveProof(copy) == .readBack, let checked = real(copy.archiveFixity?.verifiedAt, now: extras.now) {
            if let at, checked.timeIntervalSince(at) > 86_400 {
                out.append(event(.archiveChecked, at: checked, "The archived copy was read in full again and still matches."))
            } else if at == nil {
                // No archive day on record: the read-back is the one dated fact.
                out.append(event(.archiveChecked, at: checked, "The archived copy was read in full and matches."))
            }
        }
        return out
    }

    static func archiveRelativePath(_ copy: VideoRecord, root: String?) -> String {
        guard let root, !root.isEmpty, isInArchive(copy.fullPath, root: root), copy.fullPath.hasPrefix(root) else {
            return copy.filename
        }
        let relative = copy.fullPath.dropFirst(root.count).drop { $0 == "/" }
        return relative.isEmpty ? copy.filename : String(relative)
    }

    /// The path in the copy's own promote note ("Promote <ISO>: promoted from
    /// <path> · sha256 …", or "… <path> (source record … no longer in the
    /// catalog) · …") — what Promote read, as Promote wrote it down.
    /// The path Promote read, as far as the copy's own record can say:
    ///   1. `originalFullPath` when the copy's promote note names that very
    ///      path — two records of Promote's agree;
    ///   2. else the path read out of the promote note, when the note reads
    ///      only one way;
    ///   3. else `originalFullPath` when there is no promote note to consult.
    /// A note that names some OTHER path than the field (Migrate rewrote the
    /// field), or that can be read two ways, settles nothing by itself.
    static func promoteSource(of copy: VideoRecord) -> String? {
        let lines = copy.notes.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("Promote ") && $0.contains(": promoted from ") }
        if let field = copy.originalFullPath, lines.contains(where: { $0.contains(": promoted from \(field) ") || $0.hasSuffix(": promoted from \(field)") }) {
            return field
        }
        if let parsed = promotedFrom(inNotes: copy.notes) { return parsed }
        return lines.isEmpty ? copy.originalFullPath : nil
    }

    static func promotedFrom(inNotes notes: String) -> String? {
        // The path is everything up to the note's exact tails — the orphan
        // clause with its UUID, then " · sha256 <64 hex>" — so a path that
        // itself contains " · " or " (source record " is read whole (Codex #293 F5).
        // (A plain string, not a regex literal: the source sensors read this file.)
        let pattern = "^Promote \\S+: promoted from (.+?)(?: \\(source record [0-9A-Fa-f-]{36} no longer in the catalog\\))?"
            + "(?: · sha256 [0-9A-Fa-f]{64}.*)?$"
        guard let shape = try? Regex(pattern), let tail = try? Regex(" · sha256 [0-9A-Fa-f]{64}") else { return nil }
        for line in notes.split(whereSeparator: \.isNewline) {
            // More than one hash tail on the line (a folder NAMED like one): the
            // line reads two ways, and no path is taken from it (Codex #294 F1).
            guard String(line).matches(of: tail).count <= 1 else { continue }
            guard let match = String(line).wholeMatch(of: shape), let found = match.output[1].substring else { continue }
            let path = found.trimmingCharacters(in: .whitespaces)
            // A line whose hash is not a hash did not end where it should: no path is read from it.
            if path.hasPrefix("/"), !path.contains(" · sha256 ") { return path }
        }
        return nil
    }

    /// "audio verified, codec archival-safe" out of the copy's promote note
    /// ("… · readiness: <words> · …"), when Promote wrote it.
    static func readinessWords(inNotes notes: String) -> String? {
        for line in notes.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: " · readiness: ") else { continue }
            let tail = line[range.upperBound...]
            let words = tail.range(of: " · ").map { tail[..<$0.lowerBound] } ?? tail
            let trimmed = words.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - Offsite (the person's word)

    /// The latest cloud / off-site answers across the family. Any "yes" wins
    /// (a copy out of the building exists); else a "no"; "not applicable" or
    /// no answer is no step at all.
    static func offsite(_ family: Family) -> JourneyOffsite? {
        let merged = family.members.reduce([BackupAttestation]()) { BackupAttestation.merged($0, with: $1.backupAttestations) }
        let latest = BackupAttestation.latestPerKind(merged)
        let away = [BackupAttestation.Kind.cloud, .offsite].compactMap { latest[$0] }
        if let yes = away.first(where: { $0.answer == .yes }) {
            return JourneyOffsite(exists: true, label: yes.label ?? yes.kind.displayName, at: yes.attestedAt)
        }
        if let no = away.first(where: { $0.answer == .no }) {
            return JourneyOffsite(exists: false, label: no.kind.displayName, at: no.attestedAt)
        }
        return nil
    }

    // MARK: - Notes (history lines, Update lines, the rest)

    /// The row's `notes`, read once: dated history lines become events, the
    /// archive's Update lines are the person's acts, and everything else
    /// (ffprobe text, undated lines) is kept apart as technical notes.
    @MainActor
    struct NoteLines {
        struct Update: Equatable {
            let at: Date?
            let reason: String
        }

        var events: [JourneyEvent] = []
        var updates: [Update] = []
        var technical: [String] = []
        /// Every date a history line carries (evidence for "catalogued by").
        var stamps: [Date] = []

        init(rec: VideoRecord, copy: VideoRecord?, now: Date = Date()) {
            for raw in rec.notes.split(whereSeparator: \.isNewline) {
                let line = String(raw)
                if line.hasPrefix(Self.updatePrefix) {
                    // An Update line with a date that cannot be real is kept as text, not as an act.
                    if let update = Self.update(line), FileJourneyBuilder.real(update.at, now: now) != nil {
                        updates.append(update)
                    } else {
                        technical.append(line)
                    }
                    continue
                }
                guard let parsed = VideoScanModel.parseRelocateEventsFromNotes(line).first else { continue }
                if let at = parsed.timestamp { stamps.append(at) }
                switch parsed.kind {
                case .freeForm:
                    technical.append(line)
                case let kind where parsed.timestamp == nil && [.reconcile, .relocate, .reformat, .promote].contains(kind):
                    // A stamped history line whose stamp cannot be read: kept, not dated.
                    technical.append(line)
                case .promote where copy != nil:
                    // The archive event is built from the copy record itself.
                    break
                default:
                    let at = parsed.timestamp ?? (parsed.kind == .combine ? rec.dateCreatedRaw : nil)
                    // A promote note is a log line ("… · sha256 … · readiness: …"):
                    // only its first clause is a sentence.
                    let words = parsed.kind == .promote
                        ? String(parsed.sentence.range(of: " · ").map { parsed.sentence[..<$0.lowerBound] } ?? parsed.sentence[...])
                        : parsed.sentence
                    events.append(FileJourneyBuilder.event(parsed.kind, at: at, Self.sentenceCase(words), icon: parsed.icon))
                }
            }
            // An Update is written on the archive copy; a source row's sheet
            // still says the person made it.
            if let copy, copy.id != rec.id {
                for raw in copy.notes.split(whereSeparator: \.isNewline) {
                    if let update = Self.update(String(raw)), FileJourneyBuilder.real(update.at, now: now) != nil {
                        updates.append(update)
                    }
                }
            }
            stamps += updates.compactMap(\.at)
        }

        /// "promote: Update <ISO>: <reason> · <from> → <to> · sha256 verified…"
        static let updatePrefix = "promote: Update "

        static func update(_ line: String) -> Update? {
            guard line.hasPrefix(updatePrefix) else { return nil }
            let rest = line.dropFirst(updatePrefix.count)
            guard let separator = rest.range(of: ": ") else { return nil }
            let body = rest[separator.upperBound...]
            let reason = (body.range(of: " · ").map { body[..<$0.lowerBound] } ?? body).trimmingCharacters(in: .whitespaces)
            // A line with no readable date or no reason is not an act anyone made.
            guard let at = ISO8601DateFormatter().date(from: String(rest[..<separator.lowerBound])), !reason.isEmpty else {
                return nil
            }
            return Update(at: at, reason: reason)
        }

        static func sentenceCase(_ s: String) -> String {
            guard let first = s.first, first.isLowercase else { return s }
            return first.uppercased() + s.dropFirst()
        }
    }

    // MARK: - First and last events

    /// The first event: the file's own date, said to be exactly that, and
    /// where the catalog found it (two facts, never one).
    static func originEvent(for rec: VideoRecord) -> JourneyEvent {
        let volume = rec.originVolume ?? rec.volumeName
        let path = rec.originalFullPath ?? rec.fullPath
        let date = rec.dateModifiedRaw ?? rec.dateCreatedRaw
        let whereWords = volume.isEmpty ? "at \(path)" : "on \(volume) at \(path)"
        let sentence = date.map { "File dated \(friendlyDay($0)) (from the file's own clock) — found \(whereWords)" }
            ?? "Found \(whereWords) — the file carries no date of its own"
        return JourneyEvent(timestamp: date, displayStamp: date.map(friendlyDay) ?? "",
                            icon: JourneyEventKind.origin.defaultIcon, kind: .origin, sentence: sentence)
    }

    /// The last event: marked deleted, else what the disk says is at the
    /// row's path right now — and where the other copy of the footage is.
    static func currentStateEvent(for rec: VideoRecord, family: Family, recPresence: JourneyPresence,
                                  copyPresence: JourneyPresence?, isMarkedDeleted: Bool, now: Date,
                                  probe: (String) -> JourneyPresence) -> JourneyEvent {
        if isMarkedDeleted {
            let witnesses = VideoScanModel.parseWitnessesFromNote(rec.notes).count
            let sentence = witnesses > 0
                ? "Marked deleted — \(witnesses) backup copy reference(s) on file."
                : "Marked deleted from the catalog."
            return JourneyEvent(timestamp: now, displayStamp: "Now", icon: JourneyEventKind.retire.defaultIcon,
                                kind: .currentState, sentence: sentence)
        }
        // Unknown is drawn as a question, never as "gone" (codex 2026-10-16).
        let kind: JourneyEventKind = recPresence.isPresent ? .currentState
            : recPresence.isUnknown ? .presenceUnknown : .notAtPath
        let archived: JourneyPresence.ArchivedCopy? = family.copy.flatMap { copy in
            guard copy.id != rec.id, let copyPresence else { return nil }
            return JourneyPresence.ArchivedCopy(path: copy.fullPath, presence: copyPresence)
        }
        var sentence = JourneyPresence.currentSentence(path: rec.fullPath, presence: recPresence, archivedCopy: archived)
        // Opened on the archive copy: say where the copy it came from is.
        if let source = family.source, !source.isPurged, source.fullPath != rec.fullPath {
            sentence += " · " + JourneyPresence.otherCopyWords(path: source.fullPath, presence: probe(source.fullPath))
        }
        return JourneyEvent(timestamp: now, displayStamp: "Now", icon: kind.defaultIcon, kind: kind, sentence: sentence)
    }

    // MARK: - Detail sections (progressively less important)

    static func details(for rec: VideoRecord, technicalNotes: [String]) -> [JourneyDetailSection] {
        var sections: [JourneyDetailSection] = []
        func row(_ label: String, _ value: String) -> JourneyDetailRow? {
            value.isEmpty ? nil : JourneyDetailRow(label: label, value: value)
        }
        let media = [row("Stream type", rec.streamType.rawValue), row("Duration", rec.duration),
                     row("Size", rec.size), row("Resolution", rec.resolution),
                     row("Video codec", rec.videoCodec), row("Audio codec", rec.audioCodec),
                     row("Volume", rec.volumeName)].compactMap { $0 }
        if !media.isEmpty { sections.append(JourneyDetailSection(title: "This file", rows: media)) }

        var status = [row("Classification", rec.mediaDisposition.rawValue),
                      row("Rating", rec.starRating > 0 ? String(repeating: "\u{2605}", count: rec.starRating) : "Not rated")]
        if let partner = rec.pairedWith {
            status.append(row("Paired with", "\(partner.filename) (\(partner.streamType.rawValue))"))
        }
        sections.append(JourneyDetailSection(title: "Status", rows: status.compactMap { $0 }))

        let note = humanNote(rec)
        if !note.isEmpty { sections.append(JourneyDetailSection(title: "Your notes", text: note)) }
        if !technicalNotes.isEmpty {
            sections.append(JourneyDetailSection(title: "Technical notes", text: technicalNotes.joined(separator: "\n"),
                                                 isMachineText: true))
        }
        return sections
    }

    // MARK: - Small helpers

    /// One timeline event with the kind's own icon and a day-and-time stamp.
    static func event(_ kind: JourneyEventKind, at: Date?, _ sentence: String, icon: String? = nil) -> JourneyEvent {
        JourneyEvent(timestamp: at, displayStamp: friendlyStamp(at), icon: icon ?? kind.defaultIcon,
                     kind: kind, sentence: sentence)
    }

    /// Oldest first; events at one instant in the ladder's order; undated last.
    static func sorted(_ events: [JourneyEvent]) -> [JourneyEvent] {
        events.enumerated().sorted { lhs, rhs in
            switch (lhs.element.timestamp, rhs.element.timestamp) {
            case let (l?, r?) where l != r: return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let (a, b) = (lhs.element.kind.rank, rhs.element.kind.rank)
                return a != b ? a < b : lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// "Sep 23, 2026 at 1:47 PM"; "" for no date.
    static func friendlyStamp(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// "Sep 23, 2026" — a day, where a minute would claim too much.
    static func friendlyDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
