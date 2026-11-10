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
// TAPE GROUPING (2026-11-10, after the real folders: a source directory is
// NOT one tape — `Misc1990/` holds four). Within one source directory files
// are related by NAME first, then duration. A stem is the file name,
// lowercased, without its extension; two files are NAME-RELATED when their
// stems are equal or the longer one CONTINUES the shorter at a separator
// (`_`, `-`, space, `.`) — whole tokens, never a raw string prefix:
// `franklin_1990_p216` / `franklin_1990_p216_2` are related;
// `montana_tape_1` / `montana_tape_10` and `dan` / `dance_recital` are not.
//   * related to no other qualifying file → its own tape → `master`,
//     whatever its length;
//   * name-related AND durations within 1 % → captures of ONE tape: one
//     `master` (more pixels, then more bits, then the SHORTER stem — the
//     un-suffixed file — then the smaller path), the rest `alternateCapture`;
//   * name-related to a clearly LONGER file → not classified at all: it may
//     be a trim of that file, and the facts here cannot tell. The longer one
//     is still a master.
//
// THE CAPTURE SETUP is claimed only on the file's own evidence: the rule
// names Rick's July 2026 rig, so `captureSetup` is proposed only when the
// file carries an embedded creation date IN 2026 (its year-month goes into
// the evidence). No embedded date, or one in another year → role and carrier
// only, and the evidence says why the setup is not claimed.
//
// WHAT STANDS (reading the rows back): per field, Rick's newest decision if
// it is `confirmed` / `corrected`; otherwise ONLY the newest machine row —
// and nothing if he rejected that value. An older machine value the rule
// itself replaced never comes back. A run that stops proposing a content
// WITHDRAWS its estimate with a new inferred `role` = `unknown` row (the
// table is append-only), which then is that newest row: nothing is shown.
// Rick's own Set Role always wins over all of it (`visible`).
//
// NOT asserted, by ruling (rule 3: archived means fixed): no name and no date
// field — `tapeYear` and `digitizedOn` are refused by the door on archived
// content. The capture month is read at display time from the file's own
// embedded creation date. The tape year is the year FOLDER the archive
// filed the copy under (`…/1980-1989/1984/…` — what the Archive tab's
// "Archived To" column shows, so the sentence and the row cannot disagree),
// and it is omitted when there is none or when it is merely the capture's
// own year (a file filed by its capture stamp says nothing about the tape).
//
// Confidence: the table's CHECK requires one on an inferred row; a RULE has
// no probability, so every row carries the fixed `ProvenanceEstimateRule
// .confidence` and says what it is in `confidenceIs` (as the era job does).
// It is never displayed (events_design rule 9); nothing here reads it back.
//
// Cost: `resolve` is O(n log n) in the number of facts (one sort of stems
// per directory) plus one step per name-related PAIR — name-related stems
// are neighbours in sorted order, so unrelated files cost nothing more;
// 100,000 facts are budgeted in ProvenanceResolverTests.
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
    /// The year the rule's capture setup was in use: a file's embedded
    /// creation date must fall in it for the setup to be claimed.
    public static let setupYear = 2026
    /// The `rule` a withdrawal row's evidence names.
    public static let withdrawnRule = "withdrawn"
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
    public var durationSeconds: Double
    /// The file's own embedded creation date: decides whether the capture setup is claimed.
    public var embeddedCreatedAt: Date?
    /// "1280x720" (probe_extra).
    public var resolution: String
    /// "8" (probe_extra).
    public var bitDepth: String
    public var frameRate: String
    public var originEncoder: String?

    public init(digest: String, originalPath: String, filename: String, container: String, videoCodec: String,
                durationSeconds: Double, embeddedCreatedAt: Date? = nil, resolution: String,
                bitDepth: String, frameRate: String = "", originEncoder: String? = nil) {
        self.digest = digest
        self.originalPath = originalPath
        self.filename = filename
        self.container = container
        self.videoCodec = videoCodec
        self.durationSeconds = durationSeconds
        self.embeddedCreatedAt = embeddedCreatedAt
        self.resolution = resolution
        self.bitDepth = bitDepth
        self.frameRate = frameRate
        self.originEncoder = originEncoder
    }
}

/// One content's proposal: role and carrier, the capture setup when the
/// file's own date supports it, and one evidence text.
public struct ProvenanceProposal: Sendable, Equatable {
    /// `content.digest`'s spelling.
    public var digest: String
    public var role: ProvenanceRole
    public var carrier: String
    /// nil = not claimed (no embedded creation date in the setup's year).
    public var captureSetupID: String?
    /// Sorted-key JSON: the same facts give the same bytes, run after run.
    public var evidenceJSON: String

    /// The rows a writer appends, signed by the rule. `at` is the writer's.
    public func drafts(at: Int64) -> [CatalogRow.ProvenanceAssertionDraft] {
        var values = [(ProvenanceEstimateRule.roleField, role.rawValue), (ProvenanceEstimateRule.carrierField, carrier)]
        if let captureSetupID { values.append((ProvenanceEstimateRule.captureSetupField, captureSetupID)) }
        return values.map { field, value in
            CatalogRow.ProvenanceAssertionDraft(subjectKind: ProvenanceAssertionSubject.content, subjectID: digest, field: field,
                                                value: value, state: "inferred", by: ProvenanceEstimateRule.signer, at: at,
                                                confidence: ProvenanceEstimateRule.confidence, evidenceJSON: evidenceJSON)
        }
    }

    /// The row that takes an estimate BACK: an inferred `role` = `unknown`,
    /// signed by the rule, saying why. Appended (the table has no delete);
    /// being the newest machine row for the field, it leaves nothing standing.
    public static func withdrawal(digest: String, why: String, at: Int64) -> CatalogRow.ProvenanceAssertionDraft {
        let object: [String: Any] = ["rule": ProvenanceEstimateRule.withdrawnRule, "of": ProvenanceEstimateRule.ruleName, "why": why,
                                     "confidenceIs": ProvenanceEstimateRule.confidenceIs]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return CatalogRow.ProvenanceAssertionDraft(subjectKind: ProvenanceAssertionSubject.content, subjectID: digest,
                                                   field: ProvenanceEstimateRule.roleField, value: ProvenanceRole.unknown.rawValue,
                                                   state: "inferred", by: ProvenanceEstimateRule.signer, at: at,
                                                   confidence: ProvenanceEstimateRule.confidence,
                                                   evidenceJSON: String(bytes: data, encoding: .utf8) ?? "{}")
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
    /// An alternate capture's master, as the rule recorded it. The file
    /// name is the ORIGINAL one — evidence, never shown as the master's name
    /// (a surface asks the archive for the name Rick sees).
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
        /// Every fact handed in. Always notQualifying + byteCopies + qualified,
        /// and qualified = proposals.count + shorterUnclassified.
        public var examined = 0
        /// CONTENTS every clause of the rule held for (byte copies counted once).
        public var qualified = 0
        /// Facts some clause of the rule failed for.
        public var notQualifying = 0
        /// Qualifying facts beyond the first of one content (byte-identical files).
        public var byteCopies = 0
        /// Qualifying contents left unclassified: clearly shorter than a NAME-RELATED capture in their folder (maybe a trim).
        public var shorterUnclassified = 0
        /// Those contents, in digest order (a run withdraws an earlier estimate of one).
        public var shorterDigests: [String] = []

        public var masters: Int { proposals.lazy.filter { $0.role == .master }.count }
        public var alternates: Int { proposals.lazy.filter { $0.role == .alternateCapture }.count }
    }

    /// A fact the rule holds for, with what the grouping needs.
    struct Candidate {
        var digest: String
        var path: String
        var directory: String
        var filename: String
        /// The file name, lowercased, without its extension.
        var stem: String
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
            guard let c = candidate(fact) else { out.notQualifying += 1; continue }
            if let held = byDigest[c.digest] {
                out.byteCopies += 1
                if held.path <= c.path { continue }
            }
            byDigest[c.digest] = c
        }
        out.qualified = byDigest.count
        var byDirectory: [String: [Candidate]] = [:]
        for c in byDigest.values { byDirectory[c.directory, default: []].append(c) }
        for (_, members) in byDirectory {
            let (tapes, shorter) = tapes(in: members)
            out.shorterUnclassified += shorter.count
            out.shorterDigests += shorter
            for tape in tapes {
                guard let master = tape.min(by: outranks) else { continue }
                for c in tape {
                    let role: ProvenanceRole = c.digest == master.digest ? .master : .alternateCapture
                    let month = setupMonth(c.fact.embeddedCreatedAt)
                    out.proposals.append(ProvenanceProposal(digest: c.digest, role: role, carrier: ProvenanceEstimateRule.carrierVHS,
                                                            captureSetupID: month == nil ? nil : CaptureSetup.july2026.id,
                                                            evidenceJSON: evidence(c, master: master, tape: tape, setupMonth: month)))
                }
            }
        }
        out.proposals.sort { $0.digest < $1.digest }
        out.shorterDigests.sort()
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
        let filename = String(parts[parts.count - 1])
        return Candidate(digest: digest, path: path, directory: directory, filename: filename, stem: stem(of: filename),
                         seconds: fact.durationSeconds, pixels: pixels, bits: bits, fact: fact)
    }

    /// "Franklin_1990_P216_2.mkv" → "franklin_1990_p216_2".
    static func stem(of filename: String) -> String {
        let lower = filename.lowercased()
        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else { return lower }
        return String(lower[..<dot])
    }

    /// "2026-07" when the file's embedded creation date falls in the setup's
    /// year (UTC — the rule is pure and the same on every Mac); nil when the
    /// file has no such date or it is in another year: the setup is not claimed.
    static func setupMonth(_ created: Date?) -> String? {
        guard let created else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month], from: created)
        guard let year = parts.year, let month = parts.month, year == ProvenanceEstimateRule.setupYear else { return nil }
        return String(format: "%04d-%02d", year, month)
    }

    /// Where a stem may be continued by a suffix that still names the same tape.
    static func isSeparator(_ c: Character) -> Bool { c == "_" || c == "-" || c == " " || c == "." }

    /// Whole tokens: the stems are equal, or the longer one continues the
    /// shorter at a separator. `x` / `x_2` yes; `tape_1` / `tape_10` no.
    static func nameRelated(_ a: String, _ b: String) -> Bool {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard long.hasPrefix(short) else { return false }
        if long.count == short.count { return true }
        return isSeparator(long[long.index(long.startIndex, offsetBy: short.count)])
    }

    /// Durations within the tolerance of the longer one.
    static func sameLength(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= ProvenanceEstimateRule.durationTolerance * max(a, b)
    }

    /// One directory's candidates → its tapes (each a list of captures) and
    /// the digests left out as clearly shorter than a name-related file.
    /// Stems are sorted, so every stem that EXTENDS stem i sits in the run
    /// right after it: the inner loop stops at the first stem that does not
    /// start with it, and files with unrelated names are never compared.
    static func tapes(in members: [Candidate]) -> (tapes: [[Candidate]], shorter: [String]) {
        let sorted = members.sorted { ($0.stem, $0.path, $0.digest) < ($1.stem, $1.path, $1.digest) }
        var related: [(Int, Int)] = []
        var dropped = Set<Int>()
        for i in sorted.indices {
            var j = i + 1
            while j < sorted.count, sorted[j].stem.hasPrefix(sorted[i].stem) {
                // A raw prefix is not a relation (`tape_1` / `tape_10`): whole tokens only.
                guard nameRelated(sorted[i].stem, sorted[j].stem) else { j += 1; continue }
                if sameLength(sorted[i].seconds, sorted[j].seconds) {
                    related.append((i, j))
                } else {
                    dropped.insert(sorted[i].seconds < sorted[j].seconds ? i : j)
                }
                j += 1
            }
        }
        // Union-find over the captures that stay (C++: a disjoint-set forest in a vector).
        var parent = Array(sorted.indices)
        func root(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            return r
        }
        for (a, b) in related where !dropped.contains(a) && !dropped.contains(b) {
            let (ra, rb) = (root(a), root(b))
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        var groups: [Int: [Candidate]] = [:]
        for i in sorted.indices where !dropped.contains(i) { groups[root(i), default: []].append(sorted[i]) }
        return (groups.keys.sorted().compactMap { groups[$0] }, dropped.map { sorted[$0].digest })
    }

    /// "1280x720" → 921600; nil unless both sides are positive integers.
    static func pixelCount(_ resolution: String) -> Int? {
        let sides = resolution.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard sides.count == 2, let w = Int(sides[0].trimmingCharacters(in: .whitespaces)),
              let h = Int(sides[1].trimmingCharacters(in: .whitespaces)), w > 0, h > 0, w <= 100_000, h <= 100_000 else { return nil }
        return w * h
    }

    /// Master order: more pixels, then more bits, then the SHORTER stem (the
    /// un-suffixed file), then the smaller original path.
    static func outranks(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.pixels != b.pixels { return a.pixels > b.pixels }
        if a.bits != b.bits { return a.bits > b.bits }
        if a.stem.count != b.stem.count { return a.stem.count < b.stem.count }
        if a.path != b.path { return a.path < b.path }
        return a.digest < b.digest      // total order: two contents recorded at one path still rank one way
    }

    /// The facts the rule used, as sorted-key JSON (stable bytes).
    static func evidence(_ c: Candidate, master: Candidate, tape: [Candidate], setupMonth: String?) -> String {
        // The other captures of this tape, by name (capped: evidence is a note, not a list of a folder).
        let others = tape.filter { $0.digest != c.digest }.map(\.filename).sorted()
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
            "groupSize": tape.count,
            "nameRelation": tape.count > 1 ? "prefix" : "none",
            "groupDurationsMs": Array(tape.map { Int(($0.seconds * 1000).rounded()) }.sorted().prefix(8)),
        ]
        if let setupMonth {
            object["embeddedCreatedMonth"] = setupMonth
            object["setupStatement"] = CaptureSetup.july2026.statement
        } else {
            object["captureSetup"] = c.fact.embeddedCreatedAt == nil
                ? "not claimed: the file carries no embedded creation date"
                : "not claimed: the file's embedded creation date is not in \(ProvenanceEstimateRule.setupYear)"
        }
        if !c.fact.frameRate.isEmpty { object["frameRate"] = c.fact.frameRate }
        if let encoder = c.fact.originEncoder, !encoder.isEmpty { object["originEncoder"] = encoder }
        if !others.isEmpty { object["relatedNames"] = Array(others.prefix(8)) }
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

    /// The newest machine row of `field` — what the machine says NOW.
    static func newestMachineRow(_ rows: [CatalogRow.ProvenanceAssertionReading], field: String) -> CatalogRow.ProvenanceAssertionReading? {
        rows.filter { $0.field == field && $0.state == "inferred" && MachineEraResolver.isMachine($0.by) }.max { $0.seq < $1.seq }
    }

    /// Rick's newest decision on `field` wins when it is `confirmed` /
    /// `corrected`. Otherwise ONLY the newest machine row can stand, and it
    /// does not if Rick rejected its value: an older value the machine itself
    /// replaced is never brought back (review 2026-11-10).
    static func standing(_ rows: [CatalogRow.ProvenanceAssertionReading], field: String) -> FieldStanding? {
        let mine = rows.filter { $0.field == field }
        if let decided = mine.filter({ $0.by == ProvenanceEstimateRule.owner }).max(by: { $0.seq < $1.seq }),
           decided.state == "confirmed" || decided.state == "corrected" {
            return FieldStanding(value: decided.value, confirmed: true, row: decided)
        }
        guard let newest = newestMachineRow(mine, field: field), !MachineEraResolver.isRejected(newest, among: mine) else { return nil }
        return FieldStanding(value: newest.value, confirmed: false, row: newest)
    }

    /// THE ONE VISIBILITY RULE, for every surface (glyph, menu, Inspector,
    /// File Journey, dossier, Confirm): Rick's own role (Provenance ▸ Set
    /// Role) wins.
    ///   * his role is the estimate's → shown as it stands;
    ///   * he has no role, or set Unknown → shown as PROVISIONAL, even if he
    ///     once confirmed it (Unknown after a Confirm takes his word back);
    ///   * he set any other role → nothing is shown.
    public static func visible(_ estimate: ProvenanceEstimate, rickRole: ProvenanceRole) -> ProvenanceEstimate? {
        if rickRole == estimate.role { return estimate }
        guard rickRole == .unknown else { return nil }
        var provisional = estimate
        provisional.isConfirmed = false
        return provisional
    }

    /// Whether `rows` hold a live role from `signer` that a run may withdraw:
    /// the newest machine role row is that signer's, names a real role, and
    /// Rick has not rejected it (then nothing stands already).
    public static func withdrawable(_ rows: [CatalogRow.ProvenanceAssertionReading],
                                    signer: String = ProvenanceEstimateRule.signer) -> ProvenanceRole? {
        guard let newest = newestMachineRow(rows, field: ProvenanceEstimateRule.roleField), newest.by == signer,
              let role = ProvenanceRole(rawValue: newest.value), role != .unknown,
              !MachineEraResolver.isRejected(newest, among: rows) else { return nil }
        return role
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
        guard let row = rows.filter({ $0.field == ProvenanceEstimateRule.roleField && $0.state == "inferred"
                                          && $0.value != ProvenanceRole.unknown.rawValue })
            .max(by: { $0.seq < $1.seq }) else { return nil }
        let e = MachineEraResolver.object(row.evidenceJSON)
        var parts: [String] = []
        if let directory = e["originalDirectory"] as? String { parts.append("original folder \(directory)") }
        if let codec = e["videoCodec"] as? String, let container = e["container"] as? String { parts.append("\(codec) in \(container)") }
        if let ms = e["durationMs"] as? Int { parts.append("\(ms / 60_000) min") }
        if let size = e["resolution"] as? String, let bits = e["bitDepth"] as? Int { parts.append("\(size), \(bits)-bit") }
        if let encoder = e["originEncoder"] as? String { parts.append("written by \(encoder)") }
        if let group = e["groupSize"] as? Int {
            let names = (e["relatedNames"] as? [String] ?? []).joined(separator: ", ")
            parts.append(group == 1 ? "no other capture in that folder shares its name"
                            : "\(group) captures in that folder share its name and length" + (names.isEmpty ? "" : " (with \(names))"))
        }
        var text = "Rule \(e["rule"] as? String ?? "unknown") (\(row.by)): " + parts.joined(separator: "; ") + "."
        if let month = e["embeddedCreatedMonth"] as? String { text += " The file's embedded creation date is in \(month)." }
        if let statement = e["setupStatement"] as? String { text += " Capture setup as stated: \(statement)." }
        if let not = e["captureSetup"] as? String { text += " Capture setup \(not)." }
        return text
    }

    /// The `at` of the NEWEST machine row of the draft's field when that row
    /// already says exactly `draft` (value, signer, evidence) and Rick has not
    /// rejected it since; nil otherwise. A writer re-uses it so the door
    /// answers `.duplicate` — a second run writes nothing — while a REJECTED
    /// value is offered afresh, so the table's veto trigger answers (and is
    /// reported), and a value the rule had withdrawn or replaced is written
    /// again as a new newest row.
    public static func standingAt(of draft: CatalogRow.ProvenanceAssertionDraft,
                                  among rows: [CatalogRow.ProvenanceAssertionReading]) -> Int64? {
        guard let newest = newestMachineRow(rows, field: draft.field), newest.value == draft.value, newest.by == draft.by,
              newest.evidenceJSON == draft.evidenceJSON, !MachineEraResolver.isRejected(newest, among: rows) else { return nil }
        return newest.at
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

    /// The year folder the archive filed a copy under: the `YYYY` component
    /// that sits directly inside its decade folder `YYYY-YYYY`
    /// (`30_Video/1980-1989/1984/1984_x.mkv` → 1984). nil for a path with no
    /// such pair (not in the archive, `Undated`, a decade-only folder).
    public static func filingYear(archivePath: String) -> Int? {
        let parts = archivePath.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return nil }
        for i in 1..<(parts.count - 1) {
            let decade = parts[i - 1].split(separator: "-", omittingEmptySubsequences: false)
            guard decade.count == 2, decade[0].utf8.count == 4, decade[1].utf8.count == 4, parts[i].utf8.count == 4,
                  let from = Int(decade[0]), let to = Int(decade[1]), let year = Int(parts[i]), to == from + 9,
                  (from...to).contains(year) else { continue }
            return year
        }
        return nil
    }

    /// The tape's year for the sentence: the archive's filing year, unless
    /// it is only the year of the capture itself (then nothing is said).
    public static func tapeYear(archivePath: String?, captured: Date?, timeZone: TimeZone = .current) -> Int? {
        guard let archivePath, let filed = filingYear(archivePath: archivePath) else { return nil }
        if let captured {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            if calendar.component(.year, from: captured) == filed { return nil }
        }
        return filed
    }

    /// "Original capture of a VHS tape" — the part every surface starts with; nil for
    /// a role this slice has no words for (nothing is shown then).
    /// `masterName`: an alternate capture's master as the Archive tab names
    /// it, given ONLY while that master's own estimate stands; nil drops the
    /// pointer ("Alternate capture of a VHS tape").
    static func subject(_ estimate: ProvenanceEstimate, masterName: String? = nil) -> String? {
        switch estimate.role {
        case .master:
            return estimate.carrier.map { "Original capture of a \($0) tape" } ?? "Original capture"
        case .alternateCapture:
            if let masterName, !masterName.isEmpty { return "Alternate capture of the same tape as \(masterName)" }
            return estimate.carrier.map { "Alternate capture of a \($0) tape" } ?? "Alternate capture"
        default:
            return nil
        }
    }

    /// The full sentence, without its standing: "Original capture of a VHS
    /// tape from 1984, captured July 2026 using ClearClick into OBS — FFV1,
    /// 1280×720, 8-bit". `year` and `captured` are OMITTED when unknown,
    /// never invented. An alternate capture names its master (see `subject`) and stops.
    public static func sentence(_ estimate: ProvenanceEstimate, year: Int?, captured: Date?, technical: Technical?,
                                masterName: String? = nil, timeZone: TimeZone = .current) -> String? {
        guard var text = subject(estimate, masterName: masterName) else { return nil }
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
    public static func shortLine(_ estimate: ProvenanceEstimate, captured: Date?, masterName: String? = nil,
                                 timeZone: TimeZone = .current) -> String? {
        guard var text = subject(estimate, masterName: masterName) else { return nil }
        if estimate.role == .master, let captured {
            let when = monthYear(captured, timeZone: timeZone)
            if !when.isEmpty { text += ", captured \(when)" }
        }
        if estimate.isConfirmed { return "\(text). \(confirmedWords)" }
        return "Estimated: " + text.prefix(1).lowercased() + text.dropFirst() + " — not confirmed"
    }
}
