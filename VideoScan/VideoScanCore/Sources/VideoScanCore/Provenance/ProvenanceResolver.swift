// ProvenanceResolver.swift (VideoScanCore/Provenance)
// Machine-ESTIMATED provenance for archived capture masters (Rick's ruling
// 2026-11-10: "shown as PROVISIONAL … Rick may confirm a reviewed list in one
// action"; design docs/design/provenance.md §C2).
//
// One sentence: from plain facts the catalog already holds about each
// archived file, PROPOSE what it is (role, carrier, capture setup) — and,
// from the stored assertion rows of one content, say what STANDS (the
// provisional estimate, or what Rick confirmed) and the words for it.
//
// PURE: no I/O, no SQL, no clock. Three parts —
//   1. `resolve(_:)`    facts → proposals (the evidence rule + tape grouping);
//   2. `estimate(...)`  one content's assertion rows → what is shown;
//   3. `sentence(...)`  the words, one place (inspector, glyph help, File
//                       Journey, the dossier's line).
//
// THE RULE (rule `vhsCapture2026`, ALL clauses must hold; otherwise NOTHING is
// proposed — refuse rather than guess, CLAUDE.md rule 2's spirit):
//   * the original path has a DIRECTORY component `Converted_VHS_Tapes_2026`;
//   * video codec `ffv1`; container Matroska; duration ≥ 20 minutes;
//   * the probe gave a readable resolution and bit depth (they pick the
//     master, so a file without them cannot be ranked) and the digest is a
//     whole-file SHA-256.
// TAPE GROUPING: within one parent directory, the files whose duration is
// within 1 % of the LONGEST qualifying file's are captures of one tape. One
// is `master` (more pixels, then more bits, then the smallest original path —
// deterministic); the others are `alternateCapture`. A qualifying file in the
// same directory that is clearly SHORTER is not classified at all: it may be
// a trim, or another tape — the facts here cannot tell, so nothing is said.
//
// NOT asserted, by ruling (rule 3: archived means fixed): no name and no date
// field — `tapeYear` and `digitizedOn` are refused by the door on archived
// content. The capture month is read at display time from the file's own
// embedded creation date, the tape year from the record's date.
//
// Confidence: the table's CHECK requires one on an inferred row; a RULE has
// no probability, so every row carries the fixed `ProvenanceEstimateRule
// .confidence` and says what it is in `confidenceIs` (as the era job does).
// It is never displayed (events_design rule 9); nothing here reads it back.
//
// Cost: `resolve` is O(n log n) in the number of facts (one sort per
// directory); 100,000 facts are budgeted in ProvenanceResolverTests.
// Memory: one small candidate (≈ 200 B) per QUALIFYING fact, and one
// proposal (≈ 600 B with its evidence text) per classified content — worst
// case 100k contents ≈ 80 MB transient, today tens of files.
//
// (For Rick: three free functions in a namespace — a classifier, a reducer
// over an event log, and a formatter. No object, no state.)

import Foundation

/// The rule's identity and constants. An approach in the ModelLab sense
/// (`machine:<id>@r<revision>` signs its rows) — but a rule, not a model, so
/// it is not registered with a host or a payload class.
public enum ProvenanceEstimateRule {
    /// `<maker>/<family>/<variant>`, ApproachID's three-segment shape.
    public static let approachID = "catalog-rule/provenance-v1/vhs-capture-2026"
    public static let revision = 1
    /// "machine:catalog-rule/provenance-v1/vhs-capture-2026@r1" — ApproachDescriptor.signer's format.
    public static let signer = "machine:\(approachID)@r\(revision)"
    public static let ruleName = "vhsCapture2026"

    public static let folderComponent = "Converted_VHS_Tapes_2026"
    public static let videoCodec = "ffv1"
    public static let containerToken = "matroska"
    public static let minimumSeconds: Double = 20 * 60
    /// Captures of one tape agree in duration within this fraction of the longest.
    public static let durationTolerance = 0.01

    /// Fixed, per rule; required by the schema, never shown.
    public static let confidence = 0.9
    public static let confidenceIs = "a fixed value for this rule (every clause held); not a measured probability"

    public static let roleField = "role"
    public static let carrierField = "carrier"
    public static let captureSetupField = "captureSetup"
    /// The three fields an estimate asserts, in the order they are written.
    public static let fields = [roleField, carrierField, captureSetupField]

    public static let carrierVHS = "VHS"
    /// The only human who decides (the table's CHECK literal; DECISIONS 2026-11-01).
    public static let owner = "rick"
}

/// A capture rig, by a stable id. The words are the OWNER'S OWN STATEMENT,
/// not machine evidence: they are shown as "using …" and nothing technical is
/// ever taken from them (a file's resolution, bit depth and codec come from
/// its own probe).
public struct CaptureSetup: Sendable, Equatable {
    public let id: String
    /// "ClearClick into OBS" — follows "using" in the sentence.
    public let using: String
    public let format: String
    /// Who said so, and when.
    public let source: String

    /// "ClearClick into OBS; FFV1 in Matroska (Rick, 2026-11-10)".
    public var statement: String { "\(using); \(format) (\(source))" }

    /// Rick's July 2026 VHS rig — the ONE named constant.
    public static let july2026 = CaptureSetup(id: "rick-2026-07-clearclick-obs", using: "ClearClick into OBS",
                                              format: "FFV1 in Matroska", source: "Rick, 2026-11-10")

    /// The setup a stored id names; nil for an id this build does not know.
    public static func known(_ id: String?) -> CaptureSetup? { id == july2026.id ? july2026 : nil }
}

/// What the catalog already holds about one archived file.
public struct ProvenanceFact: Sendable, Equatable {
    public var digest: String
    public var originalPath: String
    public var filename: String
    public var container: String
    public var videoCodec: String
    public var audioCodec: String
    public var durationSeconds: Double
    public var embeddedCreatedAt: Date?
    /// "1280x720" (probe_extra).
    public var resolution: String
    /// "8" (probe_extra).
    public var bitDepth: String
    public var frameRate: String
    public var originEncoder: String?

    public init(digest: String, originalPath: String, filename: String, container: String, videoCodec: String,
                audioCodec: String = "", durationSeconds: Double, embeddedCreatedAt: Date? = nil, resolution: String,
                bitDepth: String, frameRate: String = "", originEncoder: String? = nil) {
        self.digest = digest
        self.originalPath = originalPath
        self.filename = filename
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.durationSeconds = durationSeconds
        self.embeddedCreatedAt = embeddedCreatedAt
        self.resolution = resolution
        self.bitDepth = bitDepth
        self.frameRate = frameRate
        self.originEncoder = originEncoder
    }
}

/// One content's proposal: three fields, one evidence text.
public struct ProvenanceProposal: Sendable, Equatable {
    /// `content.digest`'s spelling.
    public var digest: String
    public var role: ProvenanceRole
    public var carrier: String
    public var captureSetupID: String
    /// Sorted-key JSON: the same facts give the same bytes, run after run.
    public var evidenceJSON: String

    /// The rows a writer appends, signed by the rule. `at` is the writer's.
    public func drafts(at: Int64) -> [CatalogRow.ProvenanceAssertionDraft] {
        [(ProvenanceEstimateRule.roleField, role.rawValue), (ProvenanceEstimateRule.carrierField, carrier),
         (ProvenanceEstimateRule.captureSetupField, captureSetupID)].map { field, value in
            CatalogRow.ProvenanceAssertionDraft(subjectKind: ProvenanceAssertionSubject.content, subjectID: digest, field: field,
                                                value: value, state: "inferred", by: ProvenanceEstimateRule.signer, at: at,
                                                confidence: ProvenanceEstimateRule.confidence, evidenceJSON: evidenceJSON)
        }
    }
}

/// What stands for one content, read from its assertion rows.
public struct ProvenanceEstimate: Sendable, Equatable {
    public var role: ProvenanceRole
    public var carrier: String?
    public var captureSetupID: String?
    /// True only when Rick's newest decision on EVERY shown field is
    /// `confirmed` (or `corrected`). A machine row alone never makes it true.
    public var isConfirmed: Bool
    /// An alternate capture's master, as the rule recorded it.
    public var masterDigest: String?
    public var masterFilename: String?

    public init(role: ProvenanceRole, carrier: String?, captureSetupID: String?, isConfirmed: Bool,
                masterDigest: String? = nil, masterFilename: String? = nil) {
        self.role = role
        self.carrier = carrier
        self.captureSetupID = captureSetupID
        self.isConfirmed = isConfirmed
        self.masterDigest = masterDigest
        self.masterFilename = masterFilename
    }

    /// A capture master of a VHS tape — what the Archive tab's tape glyph marks.
    public var isVHSMaster: Bool { role == .master && carrier == ProvenanceEstimateRule.carrierVHS }
}

public enum ProvenanceResolver {

    // MARK: 1. Facts → proposals

    public struct Resolution: Sendable, Equatable {
        /// One per classified content, in digest order.
        public var proposals: [ProvenanceProposal] = []
        public var examined = 0
        /// Facts every clause of the rule held for (before grouping; byte copies counted once).
        public var qualified = 0
        /// Qualifying contents left unclassified: shorter than another capture in their folder.
        public var shorterUnclassified = 0

        public var masters: Int { proposals.lazy.filter { $0.role == .master }.count }
        public var alternates: Int { proposals.lazy.filter { $0.role == .alternateCapture }.count }
    }

    /// A fact the rule holds for, with what the grouping needs.
    struct Candidate {
        var digest: String
        var path: String
        var directory: String
        var filename: String
        var seconds: Double
        var pixels: Int
        var bits: Int
        var fact: ProvenanceFact
    }

    public static func resolve(_ facts: [ProvenanceFact]) -> Resolution {
        var out = Resolution()
        out.examined = facts.count
        // Byte copies are one content: the smallest original path speaks for it.
        var byDigest: [String: Candidate] = [:]
        for fact in facts {
            guard let c = candidate(fact) else { continue }
            if let held = byDigest[c.digest], held.path <= c.path { continue }
            byDigest[c.digest] = c
        }
        out.qualified = byDigest.count
        var byDirectory: [String: [Candidate]] = [:]
        for c in byDigest.values { byDirectory[c.directory, default: []].append(c) }
        for (_, members) in byDirectory {
            let longest = members.lazy.map(\.seconds).max() ?? 0
            let floor = longest * (1 - ProvenanceEstimateRule.durationTolerance)
            let tape = members.filter { $0.seconds >= floor }
            out.shorterUnclassified += members.count - tape.count
            guard let master = tape.min(by: outranks) else { continue }
            for c in tape {
                let role: ProvenanceRole = c.digest == master.digest ? .master : .alternateCapture
                out.proposals.append(ProvenanceProposal(digest: c.digest, role: role, carrier: ProvenanceEstimateRule.carrierVHS,
                                                        captureSetupID: CaptureSetup.july2026.id,
                                                        evidenceJSON: evidence(c, master: master, groupSize: tape.count)))
            }
        }
        out.proposals.sort { $0.digest < $1.digest }
        return out
    }

    /// The rule's clauses for ONE fact; nil = some clause failed (nothing is proposed).
    static func candidate(_ fact: ProvenanceFact) -> Candidate? {
        guard let digest = ProvenanceAssertionSubject.contentID(fact.digest) else { return nil }
        let path = fact.originalPath
        // A path that lost bytes in decoding (U+FFFD) or holds a NUL is not evidence.
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0 == "\u{FFFD}" || $0.value == 0 }) else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts.dropLast().contains(where: { $0 == ProvenanceEstimateRule.folderComponent }) else { return nil }
        guard fact.videoCodec.lowercased() == ProvenanceEstimateRule.videoCodec,
              fact.container.lowercased().contains(ProvenanceEstimateRule.containerToken),
              fact.durationSeconds.isFinite, fact.durationSeconds >= ProvenanceEstimateRule.minimumSeconds,
              let pixels = pixelCount(fact.resolution), let bits = Int(fact.bitDepth.trimmingCharacters(in: .whitespaces)), bits > 0
        else { return nil }
        let directory = "/" + parts.dropLast().joined(separator: "/")
        return Candidate(digest: digest, path: path, directory: directory, filename: String(parts[parts.count - 1]),
                         seconds: fact.durationSeconds, pixels: pixels, bits: bits, fact: fact)
    }

    /// "1280x720" → 921600; nil unless both sides are positive integers.
    static func pixelCount(_ resolution: String) -> Int? {
        let sides = resolution.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard sides.count == 2, let w = Int(sides[0].trimmingCharacters(in: .whitespaces)),
              let h = Int(sides[1].trimmingCharacters(in: .whitespaces)), w > 0, h > 0, w <= 100_000, h <= 100_000 else { return nil }
        return w * h
    }

    /// Master order: more pixels, then more bits, then the smaller original path.
    static func outranks(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.pixels != b.pixels { return a.pixels > b.pixels }
        if a.bits != b.bits { return a.bits > b.bits }
        if a.path != b.path { return a.path < b.path }
        return a.digest < b.digest      // total order: two contents recorded at one path still rank one way
    }

    /// The facts the rule used, as sorted-key JSON (stable bytes).
    static func evidence(_ c: Candidate, master: Candidate, groupSize: Int) -> String {
        var object: [String: Any] = [
            "rule": ProvenanceEstimateRule.ruleName,
            "confidenceIs": ProvenanceEstimateRule.confidenceIs,
            "pathComponent": ProvenanceEstimateRule.folderComponent,
            "originalDirectory": c.directory,
            "originalFilename": c.filename,
            "videoCodec": c.fact.videoCodec.lowercased(),
            "container": c.fact.container,
            "durationMs": Int((c.seconds * 1000).rounded()),
            "resolution": c.fact.resolution,
            "bitDepth": c.bits,
            "groupSize": groupSize,
            "setupStatement": CaptureSetup.july2026.statement,
        ]
        if !c.fact.frameRate.isEmpty { object["frameRate"] = c.fact.frameRate }
        if let encoder = c.fact.originEncoder, !encoder.isEmpty { object["originEncoder"] = encoder }
        if c.digest != master.digest {
            object["masterDigest"] = master.digest
            object["masterFilename"] = master.filename
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    // MARK: 2. Stored rows → what stands

    /// What one field's rows say now.
    struct FieldStanding: Equatable {
        var value: String
        var confirmed: Bool
        /// The row the value came from.
        var row: CatalogRow.ProvenanceAssertionReading
    }

    /// Rick's newest decision on `field` wins: `confirmed` / `corrected` is
    /// the value; a `rejected` leaves only machine rows whose value he has
    /// not rejected since. No human row → the newest live machine row.
    static func standing(_ rows: [CatalogRow.ProvenanceAssertionReading], field: String) -> FieldStanding? {
        let mine = rows.filter { $0.field == field }
        if let decided = mine.filter({ $0.by == ProvenanceEstimateRule.owner }).max(by: { $0.seq < $1.seq }),
           decided.state == "confirmed" || decided.state == "corrected" {
            return FieldStanding(value: decided.value, confirmed: true, row: decided)
        }
        let live = mine.filter { row in
            row.state == "inferred" && MachineEraResolver.isMachine(row.by) && !MachineEraResolver.isRejected(row, among: mine)
        }
        return live.max { $0.seq < $1.seq }.map { FieldStanding(value: $0.value, confirmed: false, row: $0) }
    }

    /// The estimate that stands for a content, from ALL its assertion rows
    /// (any order); nil when there is no live role, or the stored role is a
    /// key this build cannot read (never guessed into a neighbour).
    public static func estimate(fromRowsOfOneSubject rows: [CatalogRow.ProvenanceAssertionReading]) -> ProvenanceEstimate? {
        guard let role = standing(rows, field: ProvenanceEstimateRule.roleField),
              let known = ProvenanceRole(rawValue: role.value), known != .unknown else { return nil }
        let carrier = standing(rows, field: ProvenanceEstimateRule.carrierField)
        let setup = standing(rows, field: ProvenanceEstimateRule.captureSetupField)
        let confirmed = role.confirmed && (carrier?.confirmed ?? true) && (setup?.confirmed ?? true)
        // The master an alternate names rides the machine row's evidence (Rick's row carries none).
        let evidence = MachineEraResolver.object(machineRow(rows, role: role)?.evidenceJSON ?? "{}")
        return ProvenanceEstimate(role: known, carrier: carrier?.value, captureSetupID: setup?.value, isConfirmed: confirmed,
                                  masterDigest: evidence["masterDigest"] as? String, masterFilename: evidence["masterFilename"] as? String)
    }

    /// The newest machine row that proposed the standing role value.
    static func machineRow(_ rows: [CatalogRow.ProvenanceAssertionReading], role: FieldStanding) -> CatalogRow.ProvenanceAssertionReading? {
        rows.filter { $0.field == ProvenanceEstimateRule.roleField && $0.value == role.value && $0.state == "inferred" }
            .max { $0.seq < $1.seq }
    }

    /// The rule's evidence in words, for an ⓘ pop-over: what the rule saw.
    /// Never the confidence (it is not read here at all). nil = no machine row.
    public static func evidenceWords(fromRowsOfOneSubject rows: [CatalogRow.ProvenanceAssertionReading]) -> String? {
        guard let row = rows.filter({ $0.field == ProvenanceEstimateRule.roleField && $0.state == "inferred" })
            .max(by: { $0.seq < $1.seq }) else { return nil }
        let e = MachineEraResolver.object(row.evidenceJSON)
        var parts: [String] = []
        if let directory = e["originalDirectory"] as? String { parts.append("original folder \(directory)") }
        if let codec = e["videoCodec"] as? String, let container = e["container"] as? String { parts.append("\(codec) in \(container)") }
        if let ms = e["durationMs"] as? Int { parts.append("\(ms / 60_000) min") }
        if let size = e["resolution"] as? String, let bits = e["bitDepth"] as? Int { parts.append("\(size), \(bits)-bit") }
        if let encoder = e["originEncoder"] as? String { parts.append("written by \(encoder)") }
        if let group = e["groupSize"] as? Int { parts.append(group == 1 ? "the only capture of its length in that folder" : "\(group) captures of this length in that folder") }
        var text = "Rule \(e["rule"] as? String ?? "unknown") (\(row.by)): " + parts.joined(separator: "; ") + "."
        if let statement = e["setupStatement"] as? String { text += " Capture setup as stated: \(statement)." }
        return text
    }

    /// The `at` of a stored machine row that already says exactly `draft`
    /// (field, value, signer, evidence) and that Rick has not rejected since;
    /// nil when there is none. A writer re-uses it so the door answers
    /// `.duplicate` — a second run writes nothing — while a REJECTED value is
    /// offered afresh, so the table's veto trigger answers (and is reported).
    public static func standingAt(of draft: CatalogRow.ProvenanceAssertionDraft,
                                  among rows: [CatalogRow.ProvenanceAssertionReading]) -> Int64? {
        rows.filter { row in
            row.field == draft.field && row.value == draft.value && row.state == draft.state && row.by == draft.by
                && row.evidenceJSON == draft.evidenceJSON && !MachineEraResolver.isRejected(row, among: rows)
        }.max { $0.seq < $1.seq }?.at
    }

    // MARK: 3. The words

    /// The file's own technical facts for the sentence's tail; any may be empty.
    public struct Technical: Sendable, Equatable {
        public var videoCodec: String
        public var resolution: String
        public var bitDepth: String

        public init(videoCodec: String, resolution: String, bitDepth: String) {
            self.videoCodec = videoCodec
            self.resolution = resolution
            self.bitDepth = bitDepth
        }

        /// "FFV1, 1280×720, 8-bit"; nil when the probe gave none of them.
        public var words: String? {
            var parts: [String] = []
            let codec = videoCodec.trimmingCharacters(in: .whitespaces)
            if !codec.isEmpty { parts.append(codec.uppercased()) }
            let size = resolution.trimmingCharacters(in: .whitespaces)
            if !size.isEmpty { parts.append(size.lowercased().replacingOccurrences(of: "x", with: "×")) }
            if let bits = Int(bitDepth.trimmingCharacters(in: .whitespaces)), bits > 0 { parts.append("\(bits)-bit") }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
    }

    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                                 "October", "November", "December"]

    /// "July 2026" on the wall clock of `timeZone` (where the capture ran).
    public static func monthYear(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month, (1...12).contains(month) else { return "" }
        return "\(months[month - 1]) \(year)"
    }

    /// "Original capture of a VHS tape" — the part every surface starts with; nil for
    /// a role this slice has no words for (nothing is shown then).
    static func subject(_ estimate: ProvenanceEstimate) -> String? {
        switch estimate.role {
        case .master:
            return estimate.carrier.map { "Original capture of a \($0) tape" } ?? "Original capture"
        case .alternateCapture:
            return "Alternate capture of the same tape as " + (estimate.masterFilename ?? "another file in its folder")
        default:
            return nil
        }
    }

    /// The full sentence, without its standing: "Original capture of a VHS
    /// tape from 1984, captured July 2026 using ClearClick into OBS — FFV1,
    /// 1280×720, 8-bit". `year` and `captured` are OMITTED when unknown,
    /// never invented. An alternate capture names its master and stops.
    public static func sentence(_ estimate: ProvenanceEstimate, year: Int?, captured: Date?, technical: Technical?,
                                timeZone: TimeZone = .current) -> String? {
        guard var text = subject(estimate) else { return nil }
        guard estimate.role == .master else { return text }
        if let year { text += " from \(year)" }
        let when = captured.map { monthYear($0, timeZone: timeZone) } ?? ""
        let setup = CaptureSetup.known(estimate.captureSetupID)
        if !when.isEmpty { text += ", captured \(when)" }
        if let setup { text += (when.isEmpty ? ", captured" : "") + " using \(setup.using)" }
        if let tail = technical?.words { text += " — \(tail)" }
        return text
    }

    /// The labelled line (inspector, dossier): never an unqualified fact.
    public static func labelledLine(_ estimate: ProvenanceEstimate, sentence: String) -> String {
        (estimate.isConfirmed ? "Provenance (confirmed by Rick): " : "Provenance (estimated): ") + sentence
    }

    public static let confirmedWords = "Provenance confirmed by Rick."

    /// The glyph's help and the File Journey's sentence: short, with its standing.
    /// "Estimated: original capture of a VHS tape, captured July 2026 — not confirmed" /
    /// "Original capture of a VHS tape, captured July 2026. Provenance confirmed by Rick."
    public static func shortLine(_ estimate: ProvenanceEstimate, captured: Date?, timeZone: TimeZone = .current) -> String? {
        guard var text = subject(estimate) else { return nil }
        if estimate.role == .master, let captured {
            let when = monthYear(captured, timeZone: timeZone)
            if !when.isEmpty { text += ", captured \(when)" }
        }
        if estimate.isConfirmed { return "\(text). \(confirmedWords)" }
        return "Estimated: " + text.prefix(1).lowercased() + text.dropFirst() + " — not confirmed"
    }
}
