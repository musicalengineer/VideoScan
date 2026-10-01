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
// lexer), building a std::unordered_map<string, Details>.

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
        var out: [String: Details] = [:]
        var noteRecords: [String: String] = [:]
        var notePointers: [String: [String]] = [:]

        var currentPerson: String?
        var current = Details()
        var currentNoteRecord: (id: String, text: String)?

        // Open level-1 block under a person.
        enum Block { case none, occupation, residence(tag: String), typedEvent, note }
        var block: Block = .none
        var value = ""
        var date: String?
        var place: String?
        var type: String?
        var noteText = ""

        func closeBlock() {
            switch block {
            case .occupation:
                let v = value.trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { current.occupations.append(Occupation(value: v, date: date, place: place)) }
            case .residence(let tag):
                if let p = place?.trimmingCharacters(in: .whitespaces), !p.isEmpty {
                    current.residences.append(Residence(place: p, date: date, tag: tag))
                } else if tag == "RESI", !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    current.residences.append(Residence(place: value.trimmingCharacters(in: .whitespaces),
                                                        date: date, tag: tag))
                }
            case .typedEvent:
                if let t = type?.lowercased(), t.contains("occupation") || t.contains("profession") {
                    let v = value.trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty { current.occupations.append(Occupation(value: v, date: date, place: place)) }
                }
            case .note:
                let t = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { current.notes.append(t) }
            case .none:
                break
            }
            block = .none
            value = ""; date = nil; place = nil; type = nil; noteText = ""
        }

        func flushPerson() {
            closeBlock()
            if let id = currentPerson, !current.isEmpty { out[id] = current }
            currentPerson = nil
            current = Details()
        }

        func flushNoteRecord() {
            if let n = currentNoteRecord {
                noteRecords[n.id] = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            currentNoteRecord = nil
        }

        for raw in gedcomText.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let level = Int(parts[0]) else { continue }
            let tag = String(parts[1])
            let rest = parts.count == 3 ? String(parts[2]) : ""

            if level == 0 {
                flushPerson()
                flushNoteRecord()
                if parts.count == 3, tag.hasPrefix("@") {
                    let kind = rest.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                    if kind == "INDI" {
                        currentPerson = tag
                    } else if kind == "NOTE" {
                        // "0 @N1@ NOTE first line of text"
                        let text = rest.count > 4 ? String(rest.dropFirst(5)) : ""
                        currentNoteRecord = (tag, text)
                    }
                }
                continue
            }

            if var n = currentNoteRecord {
                if level == 1, tag == "CONT" { n.text += "\n" + rest }
                else if level == 1, tag == "CONC" { n.text += rest }
                currentNoteRecord = n
                continue
            }

            guard currentPerson != nil else { continue }

            if level == 1 {
                closeBlock()
                switch tag {
                case "OCCU":
                    block = .occupation; value = rest
                case "RESI", "CENS":
                    block = .residence(tag: tag); value = rest
                case "EVEN", "FACT":
                    block = .typedEvent; value = rest
                case "NOTE":
                    if rest.hasPrefix("@") {
                        notePointers[currentPerson!, default: []].append(rest.trimmingCharacters(in: .whitespaces))
                    } else {
                        block = .note; noteText = rest
                    }
                default:
                    break
                }
                continue
            }

            switch block {
            case .none:
                continue
            case .note:
                if level == 2, tag == "CONT" { noteText += "\n" + rest }
                else if level == 2, tag == "CONC" { noteText += rest }
            case .occupation, .residence, .typedEvent:
                guard level == 2 else {
                    // "3 CONC" under "2 NOTE" etc. — not ours.
                    continue
                }
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
        flushPerson()
        flushNoteRecord()

        // Resolve pointer notes.
        for (person, pointers) in notePointers {
            let texts = pointers.compactMap { noteRecords[$0] }.filter { !$0.isEmpty }
            guard !texts.isEmpty else { continue }
            out[person, default: Details()].notes.append(contentsOf: texts)
        }
        byPersonID = out
    }
}
