// GedcomLifeDetails.swift (VideoScanCore)
// The few GEDCOM person lines Life & Times needs that GedcomFamilyGraph
// deliberately does not keep: occupations (OCCU, or a typed EVEN/FACT
// "Occupation"), residences (RESI, and the place of a CENS — a census is
// the best dated residence most trees have) and note text (inline NOTE and
// NOTE records by pointer, CONT/CONC joined). GH #238 stage 1.
//
// A SIDE reader over the same text, keyed by the same @I…@ pointers, so
// the graph's parser and its loss accounting stay untouched. Values are
// verbatim; nothing is reinterpreted here.
//
// Memory: worst case is the sum of the OCCU/RESI/CENS/NOTE text in the
// file (on a 40k-person FamilySearch pull, measured shapes put that at a
// few MB) plus one dictionary entry per person who has any of them. The
// text is scanned line by line from the caller's String; nothing else is
// buffered.
//
// C++ readers: a single-pass line state machine (like a hand-written
// lexer) — `Reader` holds the state, one method per line kind — building a
// std::unordered_map<string, Details>.

import Foundation

public struct GedcomLifeDetails: Sendable {

    public struct Occupation: Sendable, Codable, Equatable {
        public let value: String
        public let date: String?
        public let place: String?
        public init(value: String, date: String? = nil, place: String? = nil) {
            self.value = value
            self.date = date
            self.place = place
        }
    }

    public struct Residence: Sendable, Codable, Equatable {
        public let place: String
        public let date: String?
        /// "RESI" or "CENS".
        public let tag: String
        public init(place: String, date: String? = nil, tag: String = "RESI") {
            self.place = place
            self.date = date
            self.tag = tag
        }
        public var year: Int? { GedcomFamilyGraph.year(in: date) }
    }

    public struct Details: Sendable, Equatable {
        public var occupations: [Occupation] = []
        public var residences: [Residence] = []
        public var notes: [String] = []
        public init(occupations: [Occupation] = [], residences: [Residence] = [], notes: [String] = []) {
            self.occupations = occupations
            self.residences = residences
            self.notes = notes
        }
        public var isEmpty: Bool { occupations.isEmpty && residences.isEmpty && notes.isEmpty }
    }

    public private(set) var byPersonID: [String: Details] = [:]

    public init(byPersonID: [String: Details] = [:]) {
        self.byPersonID = byPersonID
    }

    public subscript(personID: String) -> Details? { byPersonID[personID] }

    /// One pass over the GEDCOM text.
    public init(gedcomText: String) {
        var reader = Reader()
        for raw in gedcomText.split(whereSeparator: \.isNewline) {
            // Leading whitespace and a stray CR only: a trailing space is
            // DATA in a value that a CONC continues ("worked as a " +
            // "compositor"), so it must survive.
            let line = Self.trimLine(raw)
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let level = Int(parts[0]) else { continue }
            reader.read(level: level, tag: String(parts[1]), rest: parts.count == 3 ? String(parts[2]) : "")
        }
        byPersonID = reader.finish()
    }

    static func trimLine(_ raw: Substring) -> Substring {
        var line = raw.drop { $0 == " " || $0 == "\t" || $0 == "\u{feff}" }
        while let last = line.last, last == "\r" || last == "\n" { line = line.dropLast() }
        return line
    }

    // MARK: - Reader (the state machine)

    struct Reader {
        /// The level-1 block open under the current person.
        enum Block { case none, occupation, residence(tag: String), typedEvent, note }

        var out: [String: Details] = [:]
        var noteRecords: [String: String] = [:]
        var notePointers: [String: [String]] = [:]
        var person: String?
        var current = Details()
        var noteRecord: (id: String, text: String)?
        var block: Block = .none
        var value = ""
        var date: String?
        var place: String?
        var type: String?
        var noteText = ""

        mutating func read(level: Int, tag: String, rest: String) {
            if level == 0 { return openRecord(tag: tag, rest: rest) }
            if noteRecord != nil { return continueNoteRecord(level: level, tag: tag, rest: rest) }
            guard let id = person else { return }
            if level == 1 { return openBlock(person: id, tag: tag, rest: rest) }
            readSubLine(level: level, tag: tag, rest: rest)
        }

        mutating func finish() -> [String: Details] {
            flushPerson()
            flushNoteRecord()
            for (id, pointers) in notePointers {
                let texts = pointers.compactMap { noteRecords[$0] }.filter { !$0.isEmpty }
                if !texts.isEmpty { out[id, default: Details()].notes.append(contentsOf: texts) }
            }
            return out
        }

        /// "0 @I1@ INDI" / "0 @N1@ NOTE first line" / anything else.
        mutating func openRecord(tag: String, rest: String) {
            flushPerson()
            flushNoteRecord()
            guard tag.hasPrefix("@"), !rest.isEmpty else { return }
            let kind = rest.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if kind == "INDI" {
                person = tag
            } else if kind == "NOTE" {
                noteRecord = (tag, rest.count > 4 ? String(rest.dropFirst(5)) : "")
            }
        }

        mutating func continueNoteRecord(level: Int, tag: String, rest: String) {
            guard level == 1, var n = noteRecord else { return }
            if tag == "CONT" { n.text += "\n" + rest } else if tag == "CONC" { n.text += rest }
            noteRecord = n
        }

        mutating func openBlock(person id: String, tag: String, rest: String) {
            closeBlock()
            switch tag {
            case "OCCU": block = .occupation; value = rest
            case "RESI", "CENS": block = .residence(tag: tag); value = rest
            case "EVEN", "FACT": block = .typedEvent; value = rest
            case "NOTE" where rest.hasPrefix("@"):
                notePointers[id, default: []].append(rest.trimmingCharacters(in: .whitespaces))
            case "NOTE": block = .note; noteText = rest
            default: break
            }
        }

        mutating func readSubLine(level: Int, tag: String, rest: String) {
            switch block {
            case .none:
                return
            case .note:
                guard level == 2 else { return }
                if tag == "CONT" { noteText += "\n" + rest } else if tag == "CONC" { noteText += rest }
            case .occupation, .residence, .typedEvent:
                // "3 CONC" under "2 NOTE" etc. is not ours.
                guard level == 2 else { return }
                switch tag {
                case "DATE" where date == nil: date = rest
                case "PLAC" where place == nil: place = rest
                case "TYPE" where type == nil: type = rest
                case "CONC": value += rest
                case "CONT": value += " " + rest
                default: break
                }
            }
        }

        mutating func closeBlock() {
            let v = value.trimmingCharacters(in: .whitespaces)
            switch block {
            case .occupation where !v.isEmpty:
                current.occupations.append(Occupation(value: v, date: date, place: place))
            case .residence(let tag):
                let p = place?.trimmingCharacters(in: .whitespaces) ?? ""
                if !p.isEmpty {
                    current.residences.append(Residence(place: p, date: date, tag: tag))
                } else if tag == "RESI", !v.isEmpty {
                    current.residences.append(Residence(place: v, date: date, tag: tag))
                }
            case .typedEvent where !v.isEmpty && Self.isOccupationType(type):
                current.occupations.append(Occupation(value: v, date: date, place: place))
            case .note:
                let t = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { current.notes.append(t) }
            default:
                break
            }
            block = .none
            value = ""; date = nil; place = nil; type = nil; noteText = ""
        }

        static func isOccupationType(_ type: String?) -> Bool {
            guard let t = type?.lowercased() else { return false }
            return t.contains("occupation") || t.contains("profession")
        }

        mutating func flushPerson() {
            closeBlock()
            if let id = person, !current.isEmpty { out[id] = current }
            person = nil
            current = Details()
        }

        mutating func flushNoteRecord() {
            if let n = noteRecord { noteRecords[n.id] = n.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            noteRecord = nil
        }
    }
}
