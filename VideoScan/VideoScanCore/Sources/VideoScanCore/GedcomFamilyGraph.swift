// GedcomFamilyGraph.swift (VideoScanCore)
// Minimal GEDCOM 5.5.1 reader + kinship resolver for the Family
// Archivist (Rick 2026-08-07: "I'd like the gedcom data to be
// available so a person can say 'show videos of rick's father'").
//
// Scope: exactly what kinship questions need — INDI names/sex and
// FAM husband/wife/children links, including alternate names, multiple
// parent-family links, and FamilySearch's stable `_FSFTID`. Beyond the dates
// and places below, sources, notes, and the rest of the standard are ignored.
// The graph is knowledge-in-DATA:
// parsed fresh from the user's exported .ged (App Support
// family-tree/originals/), never baked into the app.
//
// Privacy: the .ged lives OUTSIDE the repo (2026-08-03 policy — it
// names living family). This file ships only the parser.
//
// codex owns adversarial parser tests (malformed lines, missing
// pointers, cycles); the happy-path contract is pinned here-adjacent
// in GedcomFamilyGraphTests.

import CryptoKit
import Foundation

public struct GedcomFamilyGraph: Sendable {

    public struct Person: Sendable, Equatable {
        public let id: String
        /// Display name with the GEDCOM slashes stripped:
        /// "Richard Harding /Breen/ Jr" → "Richard Harding Breen Jr".
        public var name: String
        /// Additional level-1 NAME records, in file order. FamilySearch
        /// exports commonly carry both a preferred and an alternate name;
        /// discarding the latter made otherwise valid searches fail.
        public var alternateNames: [String] = []
        public var sex: String          // "M" / "F" / ""
        public var childOfFamily: String?
        /// Every FAMC link, in file order. `childOfFamily` remains the first
        /// link for source compatibility, while kinship resolution consults
        /// all recorded birth/adoptive/step families instead of silently
        /// replacing one with another.
        public var childOfFamilies: [String] = []
        public var spouseOfFamilies: [String] = []
        /// Raw GEDCOM date strings ("4 Mar 1959") — displayed verbatim,
        /// never reinterpreted (honesty over formatting).
        public var birthDate: String?
        public var deathDate: String?
        /// Raw GEDCOM "2 PLAC" text under BIRT / DEAT ("Cork, Ireland"),
        /// verbatim like the dates (2026-08-22, "trace the family back to
        /// Ireland"). Nil when the record has none.
        public var birthPlace: String?
        public var deathPlace: String?
        /// The GEDCOM surname (the part between slashes: "Richard /Breen/ Jr"
        /// → "Breen"), kept separately so a surname question ("the Breens")
        /// can count people without guessing which name token is the family
        /// name. `nil` when the NAME line had no slashes.
        public var surname: String?
        /// Surnames present only in alternate NAME records.
        public var alternateSurnames: [String] = []
        /// FamilySearch's stable person identifier (for example GVQV-NW3).
        /// This survives new exports even when file-local @I…@ pointers move.
        public var familySearchID: String?

        /// Four-digit year pulled out of the raw GEDCOM birth date ("4 JUL
        /// 1962", "ABT 1944", "BET 1930 AND 1931" → first run wins). Nil when
        /// the date has none. The raw string stays the displayed fact.
        public var birthYear: Int? { GedcomFamilyGraph.year(in: birthDate) }
        /// Same for the raw death date.
        public var deathYear: Int? { GedcomFamilyGraph.year(in: deathDate) }
        /// What the raw birth date PROVES, qualifier included ("AFT 1837"
        /// → [1838, ∞)). Date RULES (feasibility, year bounds) must use
        /// these, not `birthYear`/`deathYear`, which drop the qualifier
        /// (codex #721/#723). Nil when the date has no year.
        public var birthYearInterval: GedcomYearInterval? { GedcomYearInterval.parse(birthDate) }
        public var deathYearInterval: GedcomYearInterval? { GedcomYearInterval.parse(deathDate) }
    }

    struct Family: Sendable {
        var husband: String?
        var wife: String?
        var children: [String] = []
        /// Raw GEDCOM "1 MARR / 2 DATE" text, displayed verbatim like
        /// birth/death dates (overnight cycle 6, 2026-08-22).
        var marriageDate: String?
    }

    /// One marriage a person is recorded in: the spouse (when the tree has
    /// them) and the raw date string (when the family has a MARR date).
    public struct Marriage: Sendable, Equatable {
        public let spouse: Person?
        public let date: String?
    }

    /// One recorded FAM involving a person. Keeping the family pointer and
    /// its own children together prevents renderers from accidentally
    /// assigning children from one marriage to another spouse.
    public struct FamilyUnit: Sendable, Equatable {
        public let id: String
        public let spouse: Person?
        public let children: [Person]
        public let marriageDate: String?
    }

    public private(set) var people: [String: Person] = [:]
    /// Internal (not private) so the merge and writer extensions in this
    /// module can read the family table; the setter stays here.
    private(set) var families: [String: Family] = [:]
    /// The home/root people, in order. One entry per source file: the
    /// FIRST `0 @…@ INDI` record in file order (2026-08-26, "trace … from
    /// …" resolved the owner as "Rick Breen" and declined). GEDCOM has no
    /// home-person tag; getmyancestors, FamilySearch, Ancestry and Gramps
    /// all write the home/root person first, so this is the best
    /// available "who is 'me'" hint when the owner's name has no exact
    /// tree record. It is an ASSUMPTION — callers say so in their basis
    /// line. A merged tree (2026-08-27, Rick's pull + Donna's pull) has
    /// one root per source, recorded explicitly in its HEAD
    /// (`1 _VS_ROOT @I…@`, see GedcomFamilyGraph+Writer) so the second
    /// root does not depend on file order. Empty for a tree with no people.
    public private(set) var rootPersonIDs: [String] = []
    /// The first root — the single-root view every earlier caller used.
    public var rootPersonID: String? { rootPersonIDs.first }
    /// `_FSFTID` → file-local pointer, built once at parse. FamilySearch's
    /// identifier survives re-exports when @I…@ pointers move, so it is the
    /// one stable way to say "this record is me" (2026-08-26, owner pin).
    private(set) var personIDByFamilySearchID: [String: String] = [:]

    /// Where this tree came from, when loaded from a file (2026-08-22,
    /// "what is GEDCOM / where does your tree come from"). Nil for a
    /// graph parsed from text (tests, imports).
    public var sourceFileName: String?
    public var sourceDirectory: String?
    public var sourceModifiedAt: Date?
    /// Every export this tree was built from, in root order. A plain
    /// export names one file (its own); a merged file names the pulls it
    /// was merged from, read back from its HEAD (`1 _VS_SOURCE name`).
    /// Empty for a graph parsed from text with no such HEAD lines.
    ///
    /// Basenames only, and they MAY REPEAT (codex #823): two pulls named
    /// `pull.ged` in different folders are two distinct POSITIONS of
    /// `sourceProvenance` and two entries here. A name is a label for
    /// humans; the identity of a source is (position, sha256). Nothing
    /// looks a source up by name — the store binds by position and hash,
    /// the merge unions by (name, sha256). The one place names are
    /// de-duplicated is the in-memory merge's `sourceFileNames` (a display
    /// list); `sourceProvenance` is never de-duplicated by name.
    public private(set) var sourceFileNames: [String] = []
    /// SHA-256 (hex) of THIS graph's own source file — the bytes it was
    /// parsed from. `init?(data:fileURL:)` sets it from the same Data it
    /// parses (codex #817: parse and hash are never two reads of one
    /// path). Nil for a text parse and for a graph merged in memory. Two
    /// jobs: (1) the merge's ONLY licence to match FSID-less records by
    /// pointer — identical fingerprint = the same export re-read, so
    /// `@I42@` is the same `@I42@` (codex #775); (2) the hash carried into
    /// this graph's own provenance entry by `canonicalized()`.
    ///
    /// Carried by the codec as its OWN scalar, not derived from
    /// `sourceProvenance[0]`: a merged artifact parsed from `ab.ged` has a
    /// fingerprint of ab.ged AND provenance entries for a.ged and b.ged,
    /// so the two are different facts. Decode restores it verbatim (#809).
    public var sourceFingerprint: String?
    /// True for a file VideoScan wrote as a merge artifact (`1 _VS_MERGED Y`
    /// in HEAD) — the flag that says "derived, lossy, sources elsewhere"
    /// even when the merge had one root or one file name (codex #780).
    public private(set) var isMergedArtifact = false
    /// The HEAD `1 NOTE` (with CONT/CONC joined), as written by the merge.
    /// Nil when the file has none.
    public private(set) var headNote: String?

    // MARK: Provenance — the canonical semantics (codex #809/#810/#812/#814/#816/#817)
    //
    // Three fields describe where a graph came from and what was lost:
    //
    //   sourceProvenance   THE list of source files: positional, one entry
    //                      per source, order = merge order (A+B → [A, B];
    //                      (A+B)+C → [A, B, C]). Each entry carries the
    //                      file's basename, its SHA-256 and the number of
    //                      lines that source's parse dropped.
    //   droppedLineCount   graph-LOCAL loss: lines this graph's own parse
    //                      dropped that are attributed to NO provenance
    //                      entry.
    //   totalDroppedLineCount == droppedLineCount + Σ sourceProvenance[i].droppedLineCount
    //                      No line is ever counted twice — every dropped
    //                      line lives in exactly one of the two places.
    //
    // Two shapes satisfy that invariant:
    //   • PLAIN (as parsed): `sourceProvenance` is EMPTY and
    //     `droppedLineCount = D`, the parse's own loss. A file parse also
    //     has `sourceFileName` + `sourceFingerprint`; a text parse has
    //     neither.
    //   • CANONICAL: a plain graph WITH a file name has its D MOVED into
    //     the single entry [(name, fingerprint, D)] and local becomes 0.
    //     A merged graph is already canonical (the merge builds the list
    //     and leaves local = the un-attributable remainder). A nameless
    //     text graph cannot be listed, so it stays as it is: its loss is
    //     local. A merge ARTIFACT parsed from ab.ged is canonical too —
    //     its list is [A, B] (read back from HEAD) and any loss of the
    //     artifact's OWN re-parse stays local.
    // `canonicalized()` is idempotent and never changes the total. The
    // codec ALWAYS encodes the canonical form (list + local), so decode ==
    // encode and the total survives a round-trip (#814 was the plain
    // shape being written as list AND local: 2×D after decode).
    //
    // The merge unions the two CANONICAL lists by identity (name, sha256):
    // one entry per identity, its loss counted ONCE; two entries of the
    // same identity that disagree on the count are a `.fieldDisagreement`
    // (first kept). Local = both sides' local (only a nameless side has
    // any). So A+B+B == A+B and (A+B)+(B+C) == [A, B, C] (#810).
    //
    // The store binds sources to entries POSITIONALLY — sources[i] ↔
    // physicalSources[i] — and refuses (not promoted) on any count/name/
    // hash mismatch (#816, `bindSources`), which is also the TOCTOU guard:
    // the entry's hash came from the parsed bytes, the store's from a
    // fresh read; they must agree (#817).
    //
    // LOGICAL vs PHYSICAL (codex #822/#823): `sourceProvenance` is the
    // LOGICAL list — what the tree was merged from. The PHYSICAL sources
    // are the files the store must hash to reproduce this graph:
    //   • an in-memory merge (CLI: A+B) or a plain file parse — the
    //     physical files ARE the logical ones (same list, positional);
    //   • a merge ARTIFACT parsed from disk (the app's "Add to current
    //     tree" writes ONE ab.ged whose HEAD lists A and B) — the physical
    //     source is ab.ged itself (its own name + same-bytes fingerprint);
    //     the logical list [A, B] rides along unchanged and is recorded
    //     by the store as the manifest's `logicalSources`.
    // `physicalSources` is that rule; `bindSources` binds to it.

    /// Loss accounting (codex #780, tightened codex #794): the number of
    /// lines of THIS parse that the graph does not retain and that no
    /// `sourceProvenance` entry accounts for — see the MARK above. What
    /// counts as "retained":
    ///   • a record-opening line the graph models (`0 HEAD`, `0 TRLR`,
    ///     `0 @…@ INDI`, `0 @…@ FAM`);
    ///   • an INDI/FAM line the parser stored (NAME, SEX, BIRT/DEAT
    ///     DATE+PLAC, FAMC, FAMS, _FSFTID, HUSB, WIFE, CHIL, MARR DATE);
    ///   • a HEAD line the parser stores (`_VS_*` provenance, NOTE with its
    ///     CONT/CONC) or the file-envelope boilerplate the writer
    ///     regenerates (SOUR/DEST/DATE/GEDC/CHAR/LANG/SUBM/SUBN/FILE/COPR/
    ///     PLAC and their sub-lines) — these describe the file, not the
    ///     family, so they are neither kept nor counted as lost.
    /// Everything else counts: other INDI/FAM events, sources, notes, media
    /// and their sub-lines, unknown HEAD tags, and every top-level record
    /// the graph has no model for (SOUR, OBJE, NOTE, REPO, SUBM, …) with
    /// all its sub-lines. Lines without a valid `<level> <tag>` prefix are
    /// not GEDCOM lines and are not counted.
    public private(set) var droppedLineCount = 0
    /// One source export this tree was built from, with the fingerprint
    /// and loss recorded when it was read (codex #794): written to a
    /// merged .ged as `1 _VS_SOURCE name` / `2 _VS_SHA256 hex` /
    /// `2 _VS_DROPPED n` and read back, so a chained merge (A+B → write →
    /// parse → +C) still lists A, B and C with their hashes and losses.
    public struct SourceProvenance: Sendable, Equatable {
        public var name: String
        /// SHA-256 hex of the source file; nil when the source was not
        /// fingerprinted (text parse, or an older artifact without the line).
        public var sha256: String?
        /// `droppedLineCount` of that source's parse.
        public var droppedLineCount: Int
        public init(name: String, sha256: String?, droppedLineCount: Int) {
            self.name = name; self.sha256 = sha256; self.droppedLineCount = droppedLineCount
        }
        /// Merge identity: the same file under the same name is one source.
        var identity: String { name + "\u{0}" + (sha256 ?? "") }
    }
    /// The positional source list (see the MARK above). Empty for a plain
    /// parse. Kept in step with `sourceFileNames` (one name per entry,
    /// same order). Module-settable so the codec can restore it.
    public internal(set) var sourceProvenance: [SourceProvenance] = []
    /// `canonicalized().sourceProvenance` — the list a writer or a
    /// reviewer should show: a plain file export describes itself as its
    /// own single source.
    public var effectiveProvenance: [SourceProvenance] { canonicalized().sourceProvenance }
    /// Every line lost on the way to this graph: its own unattributed loss
    /// plus the recorded loss of each listed source. Invariant under
    /// `canonicalized()`, merge (no double counting) and the codec.
    public var totalDroppedLineCount: Int {
        droppedLineCount + sourceProvenance.reduce(0) { $0 + $1.droppedLineCount }
    }
    /// The canonical shape (see the MARK above): a plain file graph's
    /// own loss moves into its single provenance entry; anything else is
    /// returned unchanged. Pure; O(1) beyond the struct copy (the record
    /// dictionaries are copy-on-write, like a shared_ptr behind a value).
    public func canonicalized() -> GedcomFamilyGraph {
        guard sourceProvenance.isEmpty, let name = sourceFileName else { return self }
        var out = self
        out.sourceProvenance = [SourceProvenance(name: name, sha256: sourceFingerprint, droppedLineCount: droppedLineCount)]
        out.droppedLineCount = 0
        if out.sourceFileNames.isEmpty { out.sourceFileNames = [name] }
        return out
    }

    /// Why `bindSources` refused. The store logs `description` and does
    /// not promote.
    public enum SourceBindingError: Error, Equatable, CustomStringConvertible {
        case countMismatch(graph: Int, sources: Int)
        case nameMismatch(index: Int, graph: String, source: String)
        case hashMismatch(index: Int, name: String, graph: String, source: String)
        public var description: String {
            switch self {
            case let .countMismatch(g, s):
                return "graph lists \(g) source\(g == 1 ? "" : "s") but \(s) \(s == 1 ? "was" : "were") given"
            case let .nameMismatch(i, g, s):
                return "source #\(i + 1) is \(s) but the graph's entry #\(i + 1) is \(g)"
            case let .hashMismatch(i, n, g, s):
                return "source #\(i + 1) \(n) hashes to \(s.prefix(12))… on disk but the graph was parsed from \(g.prefix(12))… (file changed since it was read?)"
            }
        }
    }

    /// True when this graph is a merge ARTIFACT that was parsed from a
    /// file of its own (`1 _VS_MERGED Y` in HEAD, and a fingerprint from
    /// `init?(data:fileURL:)`): its physical origin is that one file, not
    /// the pulls its HEAD lists. False for an in-memory merge (no
    /// fingerprint) and for every plain parse.
    public var bindsToOwnFile: Bool {
        isMergedArtifact && sourceFingerprint != nil && sourceFileName != nil
    }

    /// The files the store hashes and binds (see the MARK above): the
    /// artifact's own file when `bindsToOwnFile` (its loss = the
    /// artifact re-parse's local loss), else the canonical provenance
    /// list. Same shape as `sourceProvenance` so the store records both
    /// lists the same way.
    public var physicalSources: [SourceProvenance] {
        let c = canonicalized()
        if c.bindsToOwnFile, let name = c.sourceFileName {
            return [SourceProvenance(name: name, sha256: c.sourceFingerprint, droppedLineCount: c.droppedLineCount)]
        }
        return c.sourceProvenance
    }

    /// Bind the store's freshly hashed source files to this graph's
    /// PHYSICAL sources POSITIONALLY (codex #816, #822): `sources[i]` ↔
    /// `physicalSources[i]`. Canonicalises first, then requires the same
    /// count, the same basename at every position, and — when the entry
    /// already carries a hash (it does for every file parse) — the same
    /// hash (codex #817: the file must still be the bytes it was parsed
    /// from). Entries without a hash (text parse given a name) take the
    /// store's. For a merge artifact read from disk the single physical
    /// source is the artifact file and the LOGICAL `sourceProvenance` is
    /// left exactly as parsed. On success the graph is canonical and every
    /// physical entry carries the store's hash; on failure `self` is left
    /// untouched and the error says why.
    public mutating func bindSources(_ sources: [(name: String, sha256: String)]) throws {
        var out = canonicalized()
        let physical = out.physicalSources
        guard physical.count == sources.count else {
            throw SourceBindingError.countMismatch(graph: physical.count, sources: sources.count)
        }
        for (i, source) in sources.enumerated() {
            let entry = physical[i]
            guard entry.name == source.name else {
                throw SourceBindingError.nameMismatch(index: i, graph: entry.name, source: source.name)
            }
            if let carried = entry.sha256, carried != source.sha256 {
                throw SourceBindingError.hashMismatch(index: i, name: entry.name, graph: carried, source: source.sha256)
            }
        }
        if out.bindsToOwnFile {
            // Physical = the artifact file; its hash was checked above and
            // the logical list stays untouched.
            out.sourceFingerprint = sources[0].sha256
        } else {
            for (i, source) in sources.enumerated() { out.sourceProvenance[i].sha256 = source.sha256 }
            if out.sourceProvenance.count == 1, out.sourceFingerprint == nil, !out.isMergedArtifact {
                out.sourceFingerprint = sources[0].sha256
            }
        }
        self = out
    }
    /// Number of FAM records — the "families" figure in Hallie's answer.
    public var familyCount: Int { families.count }

    // MARK: Parse

    /// Assemble a graph from already-parsed records (the merge builds one
    /// this way). The FamilySearch index is rebuilt here; `rootPersonIDs`
    /// and `sourceFileNames` are taken as given.
    init(people: [String: Person], families: [String: Family],
         rootPersonIDs: [String], sourceFileNames: [String],
         isMergedArtifact: Bool = false, droppedLineCount: Int = 0,
         sourceProvenance: [SourceProvenance] = []) {
        self.people = people
        self.families = families
        self.rootPersonIDs = rootPersonIDs.filter { people[$0] != nil }
        self.sourceFileNames = sourceFileNames
        self.isMergedArtifact = isMergedArtifact
        self.droppedLineCount = droppedLineCount
        self.sourceProvenance = sourceProvenance
        var index: [String: String] = [:]
        index.reserveCapacity(people.count)
        // Sorted so a duplicated FSID (a malformed file) resolves the same
        // way parse order would: the lowest pointer wins, deterministically.
        for id in people.keys.sorted() {
            if let fsid = people[id]?.familySearchID, index[fsid] == nil { index[fsid] = id }
        }
        personIDByFamilySearchID = index
    }

    public init(gedcomText: String) {
        var currentIndi: Person?
        var currentFam: (id: String, family: Family)?
        /// Inside `0 HEAD`: VideoScan's own provenance tags live there.
        var inHead = false
        /// Inside a top-level record the graph has no model for (SOUR,
        /// OBJE, NOTE, REPO, SUBM, …): every line is counted as dropped.
        var inUnmodelledRecord = false
        /// Roots named by the HEAD (`_VS_ROOT`); when present they REPLACE
        /// the first-INDI assumption. Applied after the parse so they can
        /// be checked against the people actually read.
        var headRoots: [String] = []
        var firstIndi: String?
        /// The level-1 HEAD tag currently open (NOTE → CONT/CONC follow;
        /// _VS_SOURCE → _VS_SHA256/_VS_DROPPED follow; envelope tags →
        /// their sub-lines are boilerplate).
        var headOpenTag = ""
        /// The level-1 tag currently open under a record, for loss
        /// accounting of its sub-lines.
        var openTagKept = true
        /// Which level-1 event (BIRT/DEAT) a level-2 DATE belongs to.
        var pendingEvent: String?
        /// Same for a family record: MARR.
        var pendingFamilyEvent: String?
        let bom = CharacterSet(charactersIn: "\u{feff}")

        func flush() {
            if let person = currentIndi {
                people[person.id] = person
                if let fsid = person.familySearchID, personIDByFamilySearchID[fsid] == nil {
                    personIDByFamilySearchID[fsid] = person.id
                }
            }
            if let fam = currentFam { families[fam.id] = fam.family }
            currentIndi = nil
            currentFam = nil
            pendingEvent = nil
            pendingFamilyEvent = nil
        }

        for rawLine in gedcomText.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 2,
                                   omittingEmptySubsequences: true)
            guard parts.count >= 2, let level = Int(parts[0]) else { continue }

            if level == 0 {
                flush()
                let opener = parts[1].trimmingCharacters(in: bom)
                inHead = parts.count == 2 && opener == "HEAD"
                inUnmodelledRecord = false
                headOpenTag = ""
                // "0 @I…@ INDI" / "0 @F…@ FAM"
                if parts.count == 3, parts[1].hasPrefix("@") {
                    let id = String(parts[1])
                    switch parts[2] {
                    case "INDI":
                        currentIndi = Person(id: id, name: "", sex: "",
                                             childOfFamily: nil)
                        if firstIndi == nil { firstIndi = id }
                    case "FAM":
                        currentFam = (id, Family())
                    default:
                        // "0 @S1@ SOUR", "0 @O1@ OBJE", "0 @N1@ NOTE"…
                        inUnmodelledRecord = true
                        droppedLineCount += 1
                    }
                } else if !inHead, opener != "TRLR" {
                    inUnmodelledRecord = true
                    droppedLineCount += 1
                }
                continue
            }

            let tag = String(parts[1])
            let value = parts.count == 3 ? String(parts[2]) : ""

            if inHead {
                // VideoScan provenance (written by the merge, ignored by
                // every other reader as a custom `_` tag), and the NOTE
                // with its GEDCOM continuation lines (CONT = newline,
                // CONC = same line). Envelope boilerplate is neither kept
                // nor counted (see `droppedLineCount`).
                var kept = true
                if level == 1 {
                    headOpenTag = tag
                    switch tag {
                    case "_VS_ROOT" where value.hasPrefix("@"): headRoots.append(value)
                    case "_VS_SOURCE" where !value.isEmpty:
                        sourceFileNames.append(value)
                        sourceProvenance.append(SourceProvenance(name: value, sha256: nil, droppedLineCount: 0))
                    case "_VS_MERGED": isMergedArtifact = value.uppercased().hasPrefix("Y")
                    case "NOTE": headNote = value
                    default:
                        kept = Self.headEnvelopeTags.contains(tag)
                        if !kept { headOpenTag = "" }
                    }
                } else if level == 2, headOpenTag == "NOTE" {
                    if tag == "CONT" { headNote = (headNote ?? "") + "\n" + value }
                    else if tag == "CONC" { headNote = (headNote ?? "") + value }
                    else { kept = false }
                } else if level == 2, headOpenTag == "_VS_SOURCE", !sourceProvenance.isEmpty {
                    let last = sourceProvenance.count - 1
                    switch tag {
                    case "_VS_SHA256" where !value.isEmpty: sourceProvenance[last].sha256 = value
                    case "_VS_DROPPED":
                        if let n = Int(value), n >= 0 { sourceProvenance[last].droppedLineCount = n } else { kept = false }
                    default: kept = false
                    }
                } else {
                    kept = Self.headEnvelopeTags.contains(headOpenTag)
                }
                if !kept { droppedLineCount += 1 }
                continue
            }
            if inUnmodelledRecord {
                droppedLineCount += 1
                continue
            }
            if var person = currentIndi {
                if level == 1 { openTagKept = Self.keptPersonTags.contains(tag) }
                if !Self.applyPersonLine(level: level, tag: tag, value: value,
                                         person: &person, pendingEvent: &pendingEvent)
                    || (level >= 2 && !openTagKept) {
                    droppedLineCount += 1
                }
                currentIndi = person
            } else if var fam = currentFam {
                if level == 1 { openTagKept = Self.keptFamilyTags.contains(tag) }
                if !Self.applyFamilyLine(level: level, tag: tag, value: value,
                                         family: &fam.family,
                                         pendingEvent: &pendingFamilyEvent)
                    || (level >= 2 && !openTagKept) {
                    droppedLineCount += 1
                }
                currentFam = fam
            }
        }
        flush()
        let named = headRoots.filter { people[$0] != nil }
        rootPersonIDs = named.isEmpty ? [firstIndi].compactMap { $0 } : named
    }

    /// Parse a file: ONE read of the bytes, then `init?(data:fileURL:)`.
    public init?(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        self.init(data: data, fileURL: fileURL)
    }

    /// Parse `data` as the contents of `fileURL` and fingerprint THE SAME
    /// BYTES (codex #817): `sourceFingerprint` = SHA-256(data), so the
    /// digest a graph carries is the digest of what it was parsed from,
    /// never a second read of a path that may have changed meanwhile.
    /// Nil when the bytes are not UTF-8 or not a `0 HEAD … 0 TRLR` file.
    public init?(data: Data, fileURL: URL) {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let records = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = records.first, let last = records.last,
              first.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")) == "0 HEAD",
              last.uppercased() == "0 TRLR" else { return nil }
        self.init(gedcomText: text)
        sourceFingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        sourceFileName = fileURL.lastPathComponent
        if sourceFileNames.isEmpty { sourceFileNames = [fileURL.lastPathComponent] }
        sourceDirectory = fileURL.deletingLastPathComponent().path
        sourceModifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    /// Recorded family units in the person's FAMS order. Missing pointers
    /// are ignored; children never migrate between units.
    public func familyUnits(of person: Person) -> [FamilyUnit] {
        person.spouseOfFamilies.compactMap { familyID in
            guard let family = families[familyID] else { return nil }
            let isHusband = family.husband == person.id
            let isWife = family.wife == person.id
            // A FAMS pointer is evidence only when the reciprocal FAM record
            // names this person in exactly one partner role. Dangling pointers
            // and self-spouse records must not manufacture a family unit.
            guard isHusband != isWife else { return nil }
            let spouseID = isHusband ? family.wife : family.husband
            return FamilyUnit(
                id: familyID,
                spouse: spouseID.flatMap { people[$0] },
                // A corrupt self-child pointer must not render the root again
                // as their own descendant.
                children: family.children.compactMap {
                    $0 == person.id ? nil : people[$0]
                },
                marriageDate: family.marriageDate)
        }
    }

    /// The sidebar / card life-dates line (moved here from the Family
    /// Tree model 2026-08-29 so the compiled index can carry it). Years
    /// when both dates carry one ("1929–2008"); otherwise the raw GEDCOM
    /// text, prefixed so "b."/"d." is explicit. Never claims "Living" —
    /// absence of a death date is not evidence.
    public static func lifeYearsLabel(birth: String?, death: String?) -> String? {
        let birthYear = year(in: birth)
        let deathYear = year(in: death)
        switch (birthYear, deathYear) {
        case let (b?, d?):
            return "\(b)–\(d)"
        case let (b?, nil):
            if let death, !death.isEmpty { return "\(b) – d. \(death)" }
            return "b. \(b)"
        case let (nil, d?):
            if let birth, !birth.isEmpty { return "b. \(birth) – \(d)" }
            return "d. \(d)"
        case (nil, nil):
            let parts = [birth.map { "b. \($0)" }, death.map { "d. \($0)" }]
                .compactMap { $0 }
                .filter { $0.count > 3 }
            return parts.isEmpty ? nil : parts.joined(separator: " – ")
        }
    }

    /// First four-digit run in a raw GEDCOM date string, or nil.
    public static func year(in raw: String?) -> Int? {
        guard let raw else { return nil }
        var digits = ""
        for character in raw {
            if character.isNumber {
                digits.append(character)
            } else {
                if digits.count == 4, let year = Int(digits) { return year }
                digits.removeAll(keepingCapacity: true)
            }
        }
        return digits.count == 4 ? Int(digits) : nil
    }

    /// Everyone whose GEDCOM surname matches (case/diacritic-insensitive).
    /// "breens" and "the breens" are accepted spellings of "Breen" because
    /// that is how people ask ("the family tree for the Breens").
    public func people(withSurname typed: String) -> [Person] {
        var key = FamilyIdentityText.normalized(FamilyNameNormalizer.normalizeSurname(typed))
        if key.hasPrefix("the ") { key.removeFirst(4) }
        key = key.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return [] }
        // Surname postings narrow; the exact predicate confirms
        // (GedcomFamilyGraph+Index.swift, 2026-08-28).
        return indexedPeople(withSurnameKey: key)
    }

    // MARK: Lookup

    /// Loose name match: every typed token must appear in the person's
    /// name (case/diacritic-insensitive). "rick" won't match (nickname),
    /// but "richard" and "richard breen" will; ambiguity returns all.
    public func people(matching typed: String) -> [Person] {
        // Token postings narrow the candidates (rarest token first); every
        // survivor is re-checked with the exact per-NAME-record predicates
        // below, in the same order: token-exact, then the curated
        // diminutives, then unique ≥3-letter prefix — never a substring
        // in the middle of a name ("Ann" must not resolve to "Joanne").
        // See GedcomFamilyGraph+Index.swift (2026-08-28); the frozen
        // linear scan lives in GedcomIndexEquivalenceTests.
        indexedPeople(matching: typed)
    }

    /// The root person record, when the tree has one (see `rootPersonID`).
    public var rootPerson: Person? { rootPersonID.flatMap { people[$0] } }
    /// Every root, in source order (Rick, then Donna for the merged tree).
    public var roots: [Person] { rootPersonIDs.compactMap { people[$0] } }
    /// True when the roots are RECORDED — a VideoScan merge artifact
    /// (`_VS_MERGED` / `_VS_ROOT` in HEAD) or more than one root, which
    /// only a HEAD listing can produce — rather than the first-INDI
    /// assumption a plain export falls back to. Callers that let a root
    /// settle an otherwise ambiguous name must check this: an assumed root
    /// is a "who is me" hint, not evidence that a bare name means them
    /// (2026-08-28: "photos of Nathaniel Parker" with Sr first in file).
    /// Derived, so it survives the compiled-tree cache without a codec bump.
    public var rootsAreRecorded: Bool { isMergedArtifact || rootPersonIDs.count > 1 }

    /// The person carrying this FamilySearch ID ("GVQV-NW3"), case- and
    /// whitespace-tolerant. O(1) — indexed at parse. Nil for an empty or
    /// malformed ID or one the tree does not carry.
    public func person(familySearchID raw: String?) -> Person? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard Self.isFamilySearchID(key), let id = personIDByFamilySearchID[key] else { return nil }
        return people[id]
    }

    /// Tokens that are generational suffixes, not names: ignored on both
    /// sides of `people(namedLike:)`.
    public static let nameSuffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv", "junior", "senior"]

    /// Owner-style loose match (2026-08-26): every typed token, expanded
    /// through `diminutives`, must appear among the person's name tokens.
    /// A generational suffix (Jr/Sr/III) on the RECORD is ignored unless
    /// the typed name carries one — "Rick Breen" finds BOTH "Richard
    /// Harding Breen Jr" and "… Sr"; "Rick Breen Jr" finds only Jr. Middle
    /// names on the record side are allowed. Unlike `people(matching:)`,
    /// ambiguity is RETURNED (all candidates, name order) rather than
    /// collapsed to not-found, because the caller here has a tie-breaker
    /// (the tree root) and otherwise asks which one. Never
    /// substring-matches: "ann" still does not find "Joanne".
    public func people(namedLike typed: String) -> [Person] {
        // Predicate shared with `NameIndex` (see +NameIndex.swift) so the
        // indexed and linear paths can never drift apart.
        guard let tokens = Self.namedLikeTokens(typed) else { return [] }
        return indexedPeople(namedLikeTokens: tokens)
    }

    /// Surnames a woman may be known by that her NAME records do not
    /// carry: each spouse's surname (any marriage), lowercased tokens.
    /// FamilySearch records women under the maiden name only (live
    /// 2026-08-26: "muriel lamb breen" → not found, "muriel lamb" → found),
    /// yet the family says "Muriel Breen". Empty for men and for anyone
    /// whose own names already include the surname — a man is never found
    /// by his wife's maiden name unless a NAME record says so.
    public func marriedSurnames(of person: Person) -> [String] {
        guard person.sex == "F" else { return [] }
        let own = Set(Self.allNames(of: person).flatMap { FamilyIdentityText.tokens($0) })
        var out: [String] = []
        for marriage in marriages(of: person) {
            guard let spouse = marriage.spouse else { continue }
            for surname in [spouse.surname].compactMap({ $0 }) + spouse.alternateSurnames {
                for token in FamilyIdentityText.tokens(surname) where !own.contains(token) && !out.contains(token) {
                    out.append(token)
                }
            }
        }
        return out
    }

    /// The `people(namedLike:)` predicate WITH the married-surname rule:
    /// the strict per-NAME-record check first; failing that, a woman also
    /// matches when every typed token is either in one of her NAME
    /// records or is a spouse's surname, and at least one typed token is
    /// from the NAME record itself ("Breen" alone never means every wife
    /// of a Breen). "Muriel Lamb Breen", "Muriel Breen" → Muriel /Lamb/
    /// married to George /Breen/; "Muriel Smith" → no.
    public func matches(_ person: Person, namedLikeTokens tokens: [String]) -> Bool {
        if Self.personMatches(person, namedLikeTokens: tokens) { return true }
        return marriedSurname(of: person, satisfying: tokens) != nil
    }

    /// The spouse surname that made `matches` true for these typed tokens,
    /// or nil when the strict rule already holds (or nothing matches).
    /// Callers use it to say "Muriel Lamb (Breen)" — the record's own name
    /// with the name the family used.
    public func marriedSurname(of person: Person, satisfying tokens: [String]) -> String? {
        let married = marriedSurnames(of: person)
        guard !married.isEmpty else { return nil }
        let bySurname = tokens.filter { married.contains($0) }
        let byName = tokens.filter { !married.contains($0) }
        guard let used = bySurname.first, !byName.isEmpty,
              Self.personMatches(person, namedLikeTokens: byName) else { return nil }
        return used.capitalized
    }

    /// Curated diminutive → formal-name table (lowercased tokens). Data,
    /// not heuristics: only pairs a family archivist would vouch for.
    public static let diminutives: [String: String] = [
        "fred": "frederick", "freddy": "frederick",
        "will": "william", "bill": "william", "billy": "william", "willie": "william",
        "dave": "david", "davey": "david",
        "dick": "richard", "rich": "richard", "richie": "richard", "rick": "richard", "ricky": "richard",
        "tim": "timothy", "timmy": "timothy",
        "tom": "thomas", "tommy": "thomas",
        "jim": "james", "jimmy": "james",
        "bob": "robert", "bobby": "robert", "rob": "robert", "robbie": "robert",
        "ted": "theodore", "teddy": "theodore",
        "ed": "edward", "eddie": "edward", "ned": "edward",
        "joe": "joseph", "joey": "joseph",
        "jack": "john", "johnny": "john",
        "steve": "stephen", "steven": "stephen",
        "mike": "michael", "mickey": "michael",
        "dan": "daniel", "danny": "daniel",
        "sam": "samuel", "sammy": "samuel",
        "nate": "nathaniel", "nat": "nathaniel",
        "chris": "christopher",
        "pete": "peter",
        "geo": "george",
        "kate": "katherine", "katie": "katherine", "kathy": "katherine", "kitty": "katherine",
        "liz": "elizabeth", "lizzie": "elizabeth", "beth": "elizabeth", "betty": "elizabeth", "betsy": "elizabeth", "eliza": "elizabeth",
        "maggie": "margaret", "meg": "margaret", "peggy": "margaret",
        "molly": "mary", "polly": "mary",
        "nellie": "ellen", "nell": "ellen",
        "abby": "abigail",
        "sue": "susan", "susie": "susan", "suzie": "susan",
        "nancy": "ann",
        "sally": "sarah",
        "hattie": "harriet",
        "millie": "mildred",
        "winnie": "winifred",
        "eileen": "eileen",
    ]

    // MARK: Kinship

    public enum Relation: String, CaseIterable, Sendable {
        case father, mother, parents, brother, sister, siblings
        case son, daughter, children, husband, wife, spouse
    }

    /// Resolve "<relation> of <person>" → the related people. Empty
    /// when the graph simply doesn't record it — the archivist answers
    /// honestly rather than guessing.
    /// Every marriage the tree records for a person, in file order.
    public func marriages(of person: Person) -> [Marriage] {
        person.spouseOfFamilies.compactMap { id -> Marriage? in
            guard let family = families[id] else { return nil }
            let spouseID = [family.husband, family.wife].compactMap { $0 }.first { $0 != person.id }
            return Marriage(spouse: spouseID.flatMap { people[$0] }, date: family.marriageDate)
        }
    }

    public func relatives(_ relation: Relation, of person: Person) -> [Person] {
        func lookup(_ id: String?) -> Person? {
            guard let id else { return nil }
            return people[id]
        }
        switch relation {
        case .father:
            return uniquePeople(parentFamilies(of: person).compactMap { lookup($0.husband) })
        case .mother:
            return uniquePeople(parentFamilies(of: person).compactMap { lookup($0.wife) })
        case .parents:
            return relatives(.father, of: person) + relatives(.mother, of: person)
        case .brother, .sister, .siblings:
            let sibs = uniquePeople(parentFamilies(of: person)
                .flatMap(\.children)
                .filter { $0 != person.id }
                .compactMap { people[$0] })
            switch relation {
            case .brother: return sibs.filter { $0.sex == "M" }
            case .sister:  return sibs.filter { $0.sex == "F" }
            default:       return sibs
            }
        case .son, .daughter, .children:
            let kids = person.spouseOfFamilies
                .compactMap { families[$0] }
                .flatMap(\.children)
                .compactMap { people[$0] }
            switch relation {
            case .son:      return kids.filter { $0.sex == "M" }
            case .daughter: return kids.filter { $0.sex == "F" }
            default:        return kids
            }
        case .husband, .wife, .spouse:
            let spouses = person.spouseOfFamilies
                .compactMap { families[$0] }
                .flatMap { [$0.husband, $0.wife].compactMap { $0 } }
                .filter { $0 != person.id }
                .compactMap { people[$0] }
            switch relation {
            case .husband: return spouses.filter { $0.sex == "M" }
            case .wife:    return spouses.filter { $0.sex == "F" }
            default:       return spouses
            }
        }
    }

    private func parentFamilies(of person: Person) -> [Family] {
        let identifiers = person.childOfFamilies.isEmpty
            ? [person.childOfFamily].compactMap { $0 }
            : person.childOfFamilies
        return identifiers.compactMap { families[$0] }
    }

    private func uniquePeople(_ candidates: [Person]) -> [Person] {
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.id).inserted }
    }

    static func allNames(of person: Person) -> [String] {
        [person.name] + person.alternateNames
    }

    /// Level-1 tags the graph keeps (and the writer emits). Everything
    /// else under a record is counted in `droppedLineCount`.
    static let keptPersonTags: Set<String> = ["NAME", "SEX", "BIRT", "DEAT", "FAMC", "FAMS", "_FSFTID"]
    static let keptFamilyTags: Set<String> = ["HUSB", "WIFE", "CHIL", "MARR"]
    /// HEAD level-1 tags that describe the FILE (GEDCOM 5.5.1 header
    /// structure), regenerated by the writer: not kept, not counted lost.
    static let headEnvelopeTags: Set<String> = [
        "SOUR", "DEST", "DATE", "GEDC", "CHAR", "LANG", "SUBM", "SUBN", "FILE", "COPR", "PLAC",
    ]

    /// Returns false when the line was NOT retained (loss accounting).
    @discardableResult
    private static func applyPersonLine(
        level: Int,
        tag: String,
        value: String,
        person: inout Person,
        pendingEvent: inout String?
    ) -> Bool {
        if level == 1 { pendingEvent = (tag == "BIRT" || tag == "DEAT") ? tag : nil }
        if applyPersonEventDetail(level: level, tag: tag, value: value,
                                  person: &person, event: pendingEvent) { return true }
        switch (level, tag) {
        case (1, "NAME"):
            applyName(value, to: &person)
        case (1, "SEX"):
            person.sex = value
        case (1, "BIRT"), (1, "DEAT"):
            break
        case (1, "FAMC"):
            if !value.isEmpty, person.childOfFamily == nil {
                person.childOfFamily = value
            }
            if !value.isEmpty, !person.childOfFamilies.contains(value) {
                person.childOfFamilies.append(value)
            }
        case (1, "FAMS"):
            if !value.isEmpty, !person.spouseOfFamilies.contains(value) {
                person.spouseOfFamilies.append(value)
            }
        case (1, "_FSFTID") where person.familySearchID == nil:
            let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            if isFamilySearchID(identifier) { person.familySearchID = identifier }
        default:
            return false
        }
        return true
    }

    private static func applyPersonEventDetail(
        level: Int,
        tag: String,
        value: String,
        person: inout Person,
        event: String?
    ) -> Bool {
        guard level == 2, let event else { return false }
        switch (tag, event) {
        case ("DATE", "BIRT") where person.birthDate == nil:
            person.birthDate = value
        case ("DATE", "DEAT") where person.deathDate == nil:
            person.deathDate = value
        case ("PLAC", "BIRT") where person.birthPlace == nil && !value.isEmpty:
            person.birthPlace = value
        case ("PLAC", "DEAT") where person.deathPlace == nil && !value.isEmpty:
            person.deathPlace = value
        default:
            return false
        }
        return true
    }

    private static func applyName(_ value: String, to person: inout Person) {
        let parsed = parseName(value)
        if person.name.isEmpty {
            person.name = parsed.display
            person.surname = parsed.surname
        } else if !parsed.display.isEmpty,
                  parsed.display != person.name,
                  !person.alternateNames.contains(parsed.display) {
            person.alternateNames.append(parsed.display)
            if let surname = parsed.surname,
               surname != person.surname,
               !person.alternateSurnames.contains(surname) {
                person.alternateSurnames.append(surname)
            }
        }
    }

    /// Returns false when the line was NOT retained (loss accounting).
    @discardableResult
    private static func applyFamilyLine(
        level: Int,
        tag: String,
        value: String,
        family: inout Family,
        pendingEvent: inout String?
    ) -> Bool {
        if level == 1 { pendingEvent = tag == "MARR" ? tag : nil }
        switch (level, tag) {
        case (1, "HUSB"): family.husband = value
        case (1, "WIFE"): family.wife = value
        case (1, "CHIL"): family.children.append(value)
        case (1, "MARR"): break
        case (2, "DATE") where pendingEvent == "MARR" && family.marriageDate == nil:
            family.marriageDate = value
        default: return false
        }
        return true
    }

    /// Display and surname are the normalized spellings ("Mc Gill" →
    /// "McGill", see FamilyNameNormalizer); the raw NAME line is not kept.
    private static func parseName(_ value: String) -> (display: String, surname: String?) {
        guard let open = value.firstIndex(of: "/"),
              let close = value[value.index(after: open)...].firstIndex(of: "/") else {
            let display = value.split(separator: " ").joined(separator: " ")
            return (FamilyNameNormalizer.normalizeName(display), nil)
        }
        let raw = value[value.index(after: open)..<close]
            .trimmingCharacters(in: .whitespaces)
        let surname = raw.isEmpty ? nil : FamilyNameNormalizer.normalizeSurname(raw)
        // Rebuild the display from the three GEDCOM parts so the fused
        // surname lands in it whether or not the given name is normalized.
        let before = value[..<open].split(separator: " ").joined(separator: " ")
        let after = value[value.index(after: close)...].split(separator: " ").joined(separator: " ")
        let display = [FamilyNameNormalizer.normalizeName(before), surname ?? "", after]
            .filter { !$0.isEmpty }.joined(separator: " ")
        return (display, surname)
    }

    public static func isFamilySearchID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 3 else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return parts.joined().unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Colloquial synonyms → relations ("dad", "mom", "kids"…).
    ///
    /// PLURALS KEEP THEIR SEX (Rick, 2026-08-31). Hallie answered "Rick's
    /// brothers" with "Beth, Ellen, Matt, Tim, Timmy" because every plural
    /// gendered word was mapped to the ungendered relation — "brothers" and
    /// "sisters" both collapsed to `.siblings`, "sons" and "daughters" both
    /// to `.children`. The resolver was never at fault: `relatives(.brother,
    /// of:)` already filters to sex "M" and already returns an array, so
    /// `.brother` has always meant "all of his brothers". Only this lookup
    /// threw the distinction away, and it did so on the way in, where no
    /// downstream sensor could see it.
    ///
    /// Naming two of Rick's sisters as his brothers is the kind of wrong
    /// answer that costs Hallie a reader's trust in everything else she
    /// says, which is why the ungendered word now has to be asked for by
    /// name: "siblings" or "children", never a gendered plural.
    public static func relation(fromWord word: String) -> Relation? {
        switch word.lowercased() {
        case "father", "dad", "daddy", "papa": return .father
        case "mother", "mom", "mommy", "mama": return .mother
        case "parent", "parents": return .parents
        case "brother", "brothers": return .brother
        case "sister", "sisters": return .sister
        case "sibling", "siblings": return .siblings
        case "son", "sons": return .son
        case "daughter", "daughters": return .daughter
        case "child", "children", "kids": return .children
        case "husband", "husbands": return .husband
        case "wife", "wives": return .wife
        case "spouse", "spouses": return .spouse
        default: return nil
        }
    }

    // MARK: Compiled index hooks (GedcomFamilyGraph+Index.swift /
    // GedcomCompiledTree.swift, 2026-08-28). Kept at the bottom so the
    // two-root merge branch's edits above merge cleanly.

    /// Lazily-built derived structures (name postings, CSR topology,
    /// sidebar order); shared by every copy of this value. Read through
    /// `index`. Populated ready-made when decoded from a compiled artifact.
    let indexBox = TreeIndexBox()
    /// Read access for the compiled-artifact encoder.
    var familyTable: [String: Family] { families }
    var familySearchIndexTable: [String: String] { personIDByFamilySearchID }

    /// Assemble a graph from already-decoded records (GedcomCompiledTree).
    /// Nothing is parsed or derived here; the caller installs the index.
    init(decodedPeople: [String: Person],
         families: [String: Family],
         rootPersonIDs: [String],
         personIDByFamilySearchID: [String: String],
         sourceFileName: String?,
         sourceDirectory: String?,
         sourceModifiedAt: Date?,
         sourceFileNames: [String] = [],
         isMergedArtifact: Bool = false,
         droppedLineCount: Int = 0,
         headNote: String? = nil) {
        self.people = decodedPeople
        self.families = families
        self.rootPersonIDs = rootPersonIDs.filter { decodedPeople[$0] != nil }
        self.sourceFileNames = sourceFileNames
        self.isMergedArtifact = isMergedArtifact
        self.droppedLineCount = droppedLineCount
        self.headNote = headNote
        self.personIDByFamilySearchID = personIDByFamilySearchID
        self.sourceFileName = sourceFileName
        self.sourceDirectory = sourceDirectory
        self.sourceModifiedAt = sourceModifiedAt
    }
}
