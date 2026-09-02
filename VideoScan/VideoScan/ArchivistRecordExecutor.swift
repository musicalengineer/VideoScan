// ArchivistRecordExecutor.swift
// Deterministic answers about ONE catalog record (2026-09-02): who is in
// it (by evidence tier), when it was filmed (the Catalog's own resolved
// date), and a one-line dossier. Everything here is read from the record's
// own fields; nothing searches the catalog. The prose is a template; any
// model phrasing goes through HallieAnswerPlan / HallieGroundedComposer
// exactly as for every other route, and the facts stay these.
//
// Evidence tiers for people, strongest first, always named as such:
//   tagged     — confirmedByUserPeople (a person clicked "this is Donna")
//   detected   — detectedPeople (the face matcher, above threshold)
//   suspected  — suspectedPeople (a borderline face match)
//   mentioned  — the name is spoken in the audio transcript
// A name asked about gets ONE verdict from the highest tier that has it.
// "me" / "my name" is bound to the owner's configured name, never guessed.
//
// (For Rick: the snapshot is a plain value copied off the class on the UI
// thread — like taking a `const` struct copy under the lock and handing it
// to a worker; the executor is a pure function of that copy.)

import Foundation
import VideoScanCore

/// Sendable projection of one record: everything the presence snapshot
/// carries plus the recognition tiers, the media facts and the resolved
/// date. One record → O(1) to build; ~1 KB plus the shared text buffers
/// (transcript / captions are copy-on-write, not duplicated).
struct ArchivistRecordDossierSnapshot: Sendable, Equatable {
    let presence: ArchivistPresenceRecordSnapshot
    let detectedPeople: [String]
    let suspectedPeople: [String]
    let durationSeconds: Double
    let container: String
    let videoCodec: String
    let audioCodec: String
    let resolution: String
    let frameRate: String
    let sizeBytes: Int64
    let archiveStage: ArchiveStage
    /// Rick's typed date ("1994", "1994-12") as stored; nil when none.
    let userDate: String?
    let embeddedCreationDate: Date?
    /// The Catalog's answer to "when was this shot" with its source and
    /// precision (ArchivistTemporalSelectionDateSnapshot.capture); nil when
    /// the record has no date signal at all.
    let resolvedDate: ArchivistTemporalSelectionDateSnapshot?

    var id: UUID { presence.id }
    var fullPath: String { presence.fullPath }
    var filename: String { presence.filename }
    var confirmedPeople: [ConfirmedTag] { presence.confirmedPeople }
    var transcript: String? { presence.transcript }

    init(
        presence: ArchivistPresenceRecordSnapshot,
        detectedPeople: [String] = [],
        suspectedPeople: [String] = [],
        durationSeconds: Double = 0,
        container: String = "",
        videoCodec: String = "",
        audioCodec: String = "",
        resolution: String = "",
        frameRate: String = "",
        sizeBytes: Int64 = 0,
        archiveStage: ArchiveStage = .none,
        userDate: String? = nil,
        embeddedCreationDate: Date? = nil,
        resolvedDate: ArchivistTemporalSelectionDateSnapshot? = nil
    ) {
        self.presence = presence
        self.detectedPeople = detectedPeople
        self.suspectedPeople = suspectedPeople
        self.durationSeconds = durationSeconds
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.resolution = resolution
        self.frameRate = frameRate
        self.sizeBytes = sizeBytes
        self.archiveStage = archiveStage
        self.userDate = userDate
        self.embeddedCreationDate = embeddedCreationDate
        self.resolvedDate = resolvedDate
    }

    /// One record, read on the main actor. O(1): no catalog scan.
    @MainActor
    init(record: VideoRecord) {
        self.init(
            presence: ArchivistPresenceRecordSnapshot(record: record),
            detectedPeople: record.detectedPeople,
            suspectedPeople: record.suspectedPeople,
            durationSeconds: record.durationSeconds,
            container: record.container,
            videoCodec: record.videoCodec,
            audioCodec: record.audioCodec,
            resolution: record.resolution,
            frameRate: record.frameRate,
            sizeBytes: record.sizeBytes,
            archiveStage: record.archiveStage,
            userDate: record.userDate,
            embeddedCreationDate: record.embeddedCreationDate,
            resolvedDate: ArchivistTemporalSelectionDateSnapshot.capture(record: record))
    }
}

/// Pure, nonisolated execution over one snapshot.
enum ArchivistRecordExecutor {
    /// The verdict for one asked-about name.
    struct Verdict: Sendable, Equatable {
        enum Tier: Sendable, Equatable {
            case tagged, detected, suspected, mentioned, notFound
            /// "me" with no owner name configured.
            case unbound
        }
        /// As asked ("me", "rick").
        let asked: String
        /// As answered ("Rick Breen" for "me"; the tag's spelling when one
        /// matched; else the asked spelling, capitalised).
        let name: String
        let tier: Tier
    }

    static func execute(
        _ query: ArchivistQueryAST.Record,
        snapshot: ArchivistRecordDossierSnapshot,
        ownerName: String?
    ) -> HallieTurnExecutor.Result {
        let file = snapshot.filename
        var sentences: [String] = []
        var basis: [String] = ["record \(snapshot.fullPath)"]
        var bases: [ArchivistEvidenceBasis] = [
            .catalogField(field: "filename", queryTerm: referenceText(query.reference),
                          matchedValue: file),
        ]
        for tag in snapshot.confirmedPeople {
            bases.append(.humanPersonTag(queryIdentity: tag.name, taggedName: tag.name,
                                         confirmedAt: tag.confirmedAt))
        }
        var verdicts: [Verdict] = []
        var subject: String?

        let wantsAbout = query.operations.contains(.about)
        if wantsAbout {
            sentences.append(metadataSentence(snapshot))
            basis.append(metadataBasis(snapshot))
        }
        if wantsAbout || query.operations.contains(.date) {
            let date = ArchivistSelectionDateQuestion.answer(.when, selection: snapshot.resolvedDate)
            sentences.append(date.prose)
            basis.append(String(date.basisLine.dropFirst("Basis: ".count)))
        }
        if wantsAbout || query.operations.contains(.people) {
            let asked = (query.people ?? []).filter {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
            if asked.isEmpty {
                sentences.append(peopleSentence(snapshot, leadWithFile: !wantsAbout))
            } else {
                verdicts = asked.map { verdict(for: $0, in: snapshot, ownerName: ownerName) }
                sentences.append(contentsOf: verdictSentences(verdicts, file: file, snapshot: snapshot))
                for verdict in verdicts where verdict.tier == .mentioned {
                    bases.append(.transcriptMention(
                        queryTerm: verdict.name, model: snapshot.presence.transcriptModel))
                }
                if verdicts.count == 1, verdicts[0].tier != .unbound {
                    subject = verdicts[0].name
                }
            }
            basis.append(peopleBasis(snapshot))
        }
        if wantsAbout, let opening = transcriptOpening(snapshot.transcript) {
            sentences.append("The transcript opens: “\(opening)”")
        }

        let citation = HallieTurnExecutor.Citation(
            recordID: snapshot.id, fullPath: snapshot.fullPath, filename: file,
            playbackSeconds: nil, bases: bases)
        let description = "shape=record reference=\(referenceText(query.reference))"
            + " operations=\(query.operations.map(\.rawValue).joined(separator: ","))"
            + ((query.people?.isEmpty == false)
               ? " people=\(query.people!.joined(separator: ","))" : "")
        return HallieTurnExecutor.Result(
            route: .record,
            outcome: .answered,
            prose: sentences.joined(separator: " "),
            basisLine: "Basis: " + basis.joined(separator: "; ") + ".",
            queryDescription: description,
            citations: [citation],
            catalogPersonName: subject,
            offeredActions: offers(for: query, snapshot: snapshot))
    }

    // MARK: - People

    /// The owner's own name in a people list.
    static func isFirstPerson(_ value: String) -> Bool {
        let key = value.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        return ["me", "i", "myself", "my name", "my own name", "mine", "im"].contains(key)
    }

    static func verdict(
        for asked: String,
        in snapshot: ArchivistRecordDossierSnapshot,
        ownerName: String?
    ) -> Verdict {
        let name: String
        if isFirstPerson(asked) {
            guard let owner = ownerName?.trimmingCharacters(in: .whitespaces), !owner.isEmpty else {
                return Verdict(asked: asked, name: asked, tier: .unbound)
            }
            name = owner
        } else {
            name = asked.trimmingCharacters(in: .whitespaces)
        }
        if let tag = snapshot.confirmedPeople.first(where: { namesMatch(name, $0.name) }) {
            return Verdict(asked: asked, name: tag.name, tier: .tagged)
        }
        if let hit = snapshot.detectedPeople.first(where: { namesMatch(name, $0) }) {
            return Verdict(asked: asked, name: hit, tier: .detected)
        }
        if let hit = snapshot.suspectedPeople.first(where: { namesMatch(name, $0) }) {
            return Verdict(asked: asked, name: hit, tier: .suspected)
        }
        if let spoken = transcriptMention(of: name, in: snapshot.transcript) {
            return Verdict(asked: asked, name: spoken, tier: .mentioned)
        }
        return Verdict(asked: asked, name: displayName(name), tier: .notFound)
    }

    /// Whole-token identity match either way round: "Rick" ↔ "Rick Breen",
    /// "donna" ↔ "Donna"; never "Tim" ↔ "Timmy" (that is a different tag).
    static func namesMatch(_ a: String, _ b: String) -> Bool {
        let x = Set(identityTokens(a)), y = Set(identityTokens(b))
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x.isSubset(of: y) || y.isSubset(of: x)
    }

    /// The spelling to report when the name is spoken in the transcript:
    /// the full name if every token is there, else the first name alone
    /// ("Rick" for "Rick Breen"). Nil when neither is.
    static func transcriptMention(of name: String, in transcript: String?) -> String? {
        guard let transcript, !transcript.isEmpty else { return nil }
        let tokens = identityTokens(name)
        guard !tokens.isEmpty else { return nil }
        if ArchivistKeywordText.containsAllTokens(transcript, tokens) { return displayName(name) }
        if tokens.count > 1, let first = tokens.first,
           ArchivistKeywordText.containsAllTokens(transcript, [first]) {
            return displayName(String(name.split(separator: " ").first ?? Substring(name)))
        }
        return nil
    }

    private static func identityTokens(_ value: String) -> [String] {
        ArchivistKeywordText.tokens(value)
    }

    private static func displayName(_ name: String) -> String {
        name.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func peopleSentence(
        _ snapshot: ArchivistRecordDossierSnapshot, leadWithFile: Bool
    ) -> String {
        let tagged = snapshot.confirmedPeople.map(\.name)
        let detected = snapshot.detectedPeople.filter { name in
            !tagged.contains { namesMatch(name, $0) }
        }
        let suspected = snapshot.suspectedPeople.filter { name in
            !tagged.contains { namesMatch(name, $0) } && !detected.contains { namesMatch(name, $0) }
        }
        let lead = leadWithFile ? "In \(snapshot.filename), " : ""
        var parts: [String] = []
        if !tagged.isEmpty {
            parts.append("\(lead)\(list(tagged)) \(tagged.count == 1 ? "is" : "are") tagged (confirmed by a person).")
        }
        if !detected.isEmpty {
            parts.append((parts.isEmpty ? lead : "")
                + "the face matcher thinks \(list(detected)) \(detected.count == 1 ? "is" : "are") in it"
                + (tagged.isEmpty ? "" : " too") + " — not confirmed.")
        }
        if !suspected.isEmpty {
            parts.append((parts.isEmpty ? lead : "")
                + "maybe \(list(suspected)) — a borderline face match.")
        }
        if parts.isEmpty {
            var sentence = "\(leadWithFile ? "In \(snapshot.filename), " : "")nobody is tagged yet and the face matcher hasn't found anyone."
            if snapshot.transcript?.isEmpty == false {
                sentence += " There is a transcript — ask me whether a particular name comes up."
            }
            return capitalised(sentence)
        }
        return parts.map(capitalised).joined(separator: " ")
    }

    private static func verdictSentences(
        _ verdicts: [Verdict], file: String, snapshot: ArchivistRecordDossierSnapshot
    ) -> [String] {
        let hasTranscript = snapshot.transcript?.isEmpty == false
        return verdicts.enumerated().map { index, verdict in
            let lead = index == 0 ? "In \(file), " : ""
            let sentence: String
            switch verdict.tier {
            case .tagged:
                sentence = "\(lead)\(verdict.name) is tagged (confirmed by a person)."
            case .detected:
                sentence = "\(lead)the face matcher thinks \(verdict.name) is in it — not confirmed."
            case .suspected:
                sentence = "\(lead)\(verdict.name) is a maybe — a borderline face match, not confirmed."
            case .mentioned:
                sentence = "\(lead)\(verdict.name) isn't tagged, but someone says the name “\(verdict.name)” in the transcript."
            case .notFound:
                sentence = "\(lead)nothing for \(verdict.name) — not tagged, not detected"
                    + (hasTranscript ? ", and the name isn't in the transcript." : ", and there is no transcript to check.")
            case .unbound:
                sentence = "\(lead)I don't know your name yet — set it in Hallie's settings and ask again."
            }
            return capitalised(sentence)
        }
    }

    private static func peopleBasis(_ snapshot: ArchivistRecordDossierSnapshot) -> String {
        var parts = ["tags confirmed \(snapshot.confirmedPeople.count)",
                     "detected \(snapshot.detectedPeople.count)",
                     "suspected \(snapshot.suspectedPeople.count)"]
        if let transcript = snapshot.transcript {
            parts.append(transcript.isEmpty
                ? "transcript empty"
                : "transcript \(transcript.split(whereSeparator: \.isWhitespace).count) words"
                    + " (\(snapshot.presence.transcriptModel ?? "model unrecorded"))")
        } else {
            parts.append("no transcript")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Metadata

    static func metadataSentence(_ snapshot: ArchivistRecordDossierSnapshot) -> String {
        var facts: [String] = []
        facts.append(mediaKindPhrase(snapshot))
        let codecs = [snapshot.videoCodec, snapshot.audioCodec.isEmpty ? "" : "\(snapshot.audioCodec) audio"]
            .filter { !$0.isEmpty }
        if !codecs.isEmpty { facts.append(codecs.joined(separator: " with ")) }
        if !snapshot.resolution.isEmpty { facts.append(snapshot.resolution) }
        if snapshot.durationSeconds > 0 { facts.append("\(duration(snapshot.durationSeconds)) long") }
        if snapshot.sizeBytes > 0 { facts.append(bytes(snapshot.sizeBytes)) }
        let volume = snapshot.presence.volumeName.isEmpty
            ? VolumeReachability.volumeName(forPath: snapshot.fullPath)
            : snapshot.presence.volumeName
        var sentence = "\(snapshot.filename) is \(facts.joined(separator: ", "))"
        if !volume.isEmpty { sentence += ", on \(volume)" }
        sentence += " — \(archivePhrase(snapshot.archiveStage))."
        return sentence
    }

    private static func mediaKindPhrase(_ snapshot: ArchivistRecordDossierSnapshot) -> String {
        let container = snapshot.container.isEmpty ? "" : " \(snapshot.container)"
        switch StreamType(rawValue: snapshot.presence.streamTypeRaw) {
        case .videoAndAudio?: return "a\(container) video with sound"
        case .videoOnly?: return "a\(container) video with no audio track"
        case .audioOnly?: return "an\(container) audio-only recording"
        case .noStreams?, .ffprobeFailed?: return "a\(container) file with no readable streams"
        case nil: return "a\(container) file"
        }
    }

    private static func archivePhrase(_ stage: ArchiveStage) -> String {
        switch stage {
        case .archived: return "safely in the Master Archive"
        case .none: return "not yet archived"
        case .healthy: return "healthy, not yet archived"
        case .masterAssigned: return "master assigned, not yet archived"
        case .backedUp: return "backed up, not yet archived"
        case .readyForArchive: return "ready for the archive"
        case .manuallyDeleted: return "marked manually deleted"
        case .salvageFailed: return "salvage failed"
        }
    }

    private static func metadataBasis(_ snapshot: ArchivistRecordDossierSnapshot) -> String {
        "media \(snapshot.presence.streamTypeRaw)"
            + (snapshot.container.isEmpty ? "" : " \(snapshot.container)")
            + (snapshot.videoCodec.isEmpty ? "" : "/\(snapshot.videoCodec)")
            + (snapshot.audioCodec.isEmpty ? "" : "/\(snapshot.audioCodec)")
            + ", \(Int(snapshot.durationSeconds.rounded())) s, \(snapshot.sizeBytes) bytes"
            + ", archive stage \(snapshot.archiveStage.rawValue)"
    }

    /// The first sentence of the transcript, bounded, for the dossier.
    static func transcriptOpening(_ transcript: String?, maxCharacters: Int = 160) -> String? {
        guard let transcript else { return nil }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var end = trimmed.endIndex
        for terminator in [".", "?", "!"] {
            if let found = trimmed.range(of: terminator)?.upperBound, found < end { end = found }
        }
        var sentence = String(trimmed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if sentence.count > maxCharacters {
            sentence = String(sentence.prefix(maxCharacters)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return sentence
    }

    // MARK: - Offers

    /// The other things she can say about this record, as chips. The
    /// question names the FULL PATH so the model-free recogniser resolves
    /// it exactly whatever is selected by then.
    static func offers(
        for query: ArchivistQueryAST.Record,
        snapshot: ArchivistRecordDossierSnapshot
    ) -> [HallieTurnExecutor.OfferedAction] {
        var offers: [HallieTurnExecutor.OfferedAction] = []
        let path = snapshot.fullPath
        if !query.operations.contains(.about) {
            offers.append(.ask(question: "tell me about \(path)", label: "Tell me about it"))
        }
        if !query.operations.contains(.people), !query.operations.contains(.about) {
            offers.append(.ask(question: "who is in \(path)", label: "Who is in it"))
        }
        if !query.operations.contains(.date), !query.operations.contains(.about) {
            offers.append(.ask(question: "when was \(path) filmed", label: "When was it filmed"))
        }
        return offers
    }

    /// The question a which-one chip re-asks about one candidate: the same
    /// operations and names, against that file's full path.
    static func question(for query: ArchivistQueryAST.Record, path: String) -> String {
        if query.operations.contains(.about) { return "tell me about \(path)" }
        var parts: [String] = []
        if query.operations.contains(.people) {
            if let people = query.people, !people.isEmpty {
                parts.append("is \(list(people)) in \(path)")
            } else {
                parts.append("who is in \(path)")
            }
        }
        if query.operations.contains(.date) {
            parts.append(parts.isEmpty ? "when was \(path) filmed" : "when was it filmed")
        }
        return parts.joined(separator: " and ")
    }

    // MARK: - Wording helpers

    static func referenceText(_ reference: ArchivistQueryAST.Record.Reference) -> String {
        switch reference {
        case .currentSelection: return "selection"
        case .file(let name): return "file:\(name)"
        }
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: count)
    }

    private static func capitalised(_ sentence: String) -> String {
        guard let first = sentence.first else { return sentence }
        return first.uppercased() + sentence.dropFirst()
    }
}
