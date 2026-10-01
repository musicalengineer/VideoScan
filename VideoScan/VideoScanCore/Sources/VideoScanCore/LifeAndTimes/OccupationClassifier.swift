// OccupationClassifier.swift (VideoScanCore)
// "Were any in art or writing, or were they all labourers?" — sort the
// occupations a tree records into a dozen categories (GH #238 stage 1).
//
// Input: GEDCOM OCCU values (verbatim, often census transcriptions:
// "Ag Lab", "Labr", "Serv", "Cordwainer", "Yeoman") and, at LOWER
// confidence, explicit cues in notes text ("worked as a printer",
// "occupation: teacher", "by trade a cooper"). A note that only mentions a
// word ("his father was a farmer") is NOT read as this person's job.
//
// Matching: the text is folded (case, diacritics, punctuation → spaces) and
// tokenised; the rule table is a list of TOKEN PHRASES ("ag lab",
// "master mariner", "painter"). Every phrase found is a hit; the LONGEST
// phrase wins (so "house painter" beats "painter", "master mariner" beats
// "master", "farm labourer" beats "farm"), ties broken by table order.
// Phrases are whole tokens only — "spinner" never matches "spinster".
//
// STATUS words (spinster, widow, gentleman, scholar, pauper, annuitant,
// "living on own means", retired …) are a category of their own — not an
// occupation, and not "unknown". "Retired farmer" is farming, flagged
// retired. Period spellings are in the table ("labourer"/"laborer"/"labr",
// "husbandman", "cordwainer", "victualler", "ostler" …).
//
// Ambiguities are recorded, not guessed: a bare "painter" in a census is
// usually a house painter (trades) and says "could be an artist".
//
// Pure, table-driven; the table is built once (lazy static). C++ readers:
// think `static const std::vector<Rule>` plus a token-trie-free linear scan
// — ~400 phrases × a handful of tokens is microseconds per occupation.

import Foundation

extension LifeAndTimes {

    public enum OccupationCategory: String, Sendable, Codable, CaseIterable, Hashable, Comparable {
        case labourer
        case trades
        case farming
        case domesticService
        case military
        case clergy
        case professions
        case arts
        case writing
        case business
        case maritime
        case government
        case homeDuties
        case status
        case unknown

        public static func < (a: OccupationCategory, b: OccupationCategory) -> Bool { a.order < b.order }
        private static let orderTable: [OccupationCategory: Int] =
            Dictionary(uniqueKeysWithValues: allCases.enumerated().map { ($1, $0) })
        var order: Int { Self.orderTable[self] ?? 0 }

        public var label: String {
            switch self {
            case .labourer: return "labourer / manual work"
            case .trades: return "trades and crafts"
            case .farming: return "farming"
            case .domesticService: return "domestic service"
            case .military: return "military"
            case .clergy: return "clergy"
            case .professions: return "professions (law, medicine, teaching)"
            case .arts: return "arts (painting, music, stage)"
            case .writing: return "writing and the print trade"
            case .business: return "business and trade"
            case .maritime: return "the sea"
            case .government: return "government and public service"
            case .homeDuties: return "home duties"
            case .status: return "a status, not an occupation"
            case .unknown: return "not recognised"
            }
        }

        /// Singular / plural nouns for aggregate sentences.
        var noun: (one: String, many: String) {
            switch self {
            case .labourer: return ("labourer", "labourers")
            case .trades: return ("tradesman or craftsman", "tradesmen and craftsmen")
            case .farming: return ("farmer", "farmers")
            case .domesticService: return ("in domestic service", "in domestic service")
            case .military: return ("soldier", "soldiers")
            case .clergy: return ("clergyman", "clergy")
            case .professions: return ("professional", "professionals")
            case .arts: return ("artist or performer", "artists and performers")
            case .writing: return ("writer or printer", "writers and printers")
            case .business: return ("in business", "in business")
            case .maritime: return ("seafarer", "seafarers")
            case .government: return ("in public service", "in public service")
            case .homeDuties: return ("at home", "at home")
            case .status: return ("status only", "status only")
            case .unknown: return ("unrecognised", "unrecognised")
            }
        }
    }

    public enum OccupationEvidence: String, Sendable, Codable, Equatable {
        /// A GEDCOM OCCU value (or a typed occupation event).
        case occupationTag
        /// An explicit cue in a note ("worked as a …"). Lower confidence.
        case note
    }

    /// One recorded occupation, classified.
    public struct ClassifiedOccupation: Sendable, Codable, Equatable {
        /// The text as recorded (or the note fragment).
        public let raw: String
        public let category: OccupationCategory
        /// The canonical term the matched phrase stands for ("agricultural
        /// labourer" for "Ag Lab"); nil when unknown.
        public let term: String?
        /// Sub-kind inside a category: "law", "medicine", "teaching",
        /// "agricultural", "print trade" …
        public let detail: String?
        public let evidence: OccupationEvidence
        /// "retired farmer" → true.
        public let retired: Bool
        /// A recorded doubt ("could be an artist").
        public let ambiguity: String?
        public let date: String?

        public init(raw: String, category: OccupationCategory, term: String?, detail: String?,
                    evidence: OccupationEvidence, retired: Bool, ambiguity: String?, date: String? = nil) {
            self.raw = raw
            self.category = category
            self.term = term
            self.detail = detail
            self.evidence = evidence
            self.retired = retired
            self.ambiguity = ambiguity
            self.date = date
        }

        /// A real occupation (not a status, not unrecognised).
        public var isOccupation: Bool { category != .status && category != .unknown }
    }

    // MARK: - Classification

    public enum OccupationClassifier {

        struct Rule {
            let tokens: [String]
            let category: OccupationCategory
            let term: String
            let detail: String?
            let ambiguity: String?
        }

        /// Classify one occupation string.
        public static func classify(_ raw: String, evidence: OccupationEvidence = .occupationTag,
                                    date: String? = nil) -> ClassifiedOccupation {
            let tokens = tokenize(raw)
            let retired = tokens.contains("retired") || tokens.contains("ret") || tokens.contains("formerly")
                || tokens.contains("late")
            // Winner: the longest phrase; on a tie a real occupation beats a
            // status word ("Widow, Farmer" is farming), then the phrase that
            // comes first in the text ("Farmer and Labourer" is farming).
            var best: (rule: Rule, position: Int)?
            // Only rules whose first token is in the text can match: look
            // them up by that token (a hash probe per token, not ~450 phrase
            // scans). Positions ascend and rules keep table order, so ties
            // resolve exactly as a full in-order scan would.
            for position in tokens.indices {
                guard let candidates = rulesByFirstToken[tokens[position]] else { continue }
                for rule in candidates where tokens[position...].starts(with: rule.tokens) {
                    guard let b = best else { best = (rule, position); continue }
                    let key = (rule.tokens.count, rule.category == .status ? 0 : 1, -position)
                    let bestKey = (b.rule.tokens.count, b.rule.category == .status ? 0 : 1, -b.position)
                    if key > bestKey { best = (rule, position) }
                }
            }
            guard let rule = best?.rule else {
                if retired {
                    return ClassifiedOccupation(raw: raw, category: .status, term: "retired", detail: nil,
                                                evidence: evidence, retired: true, ambiguity: nil, date: date)
                }
                return ClassifiedOccupation(raw: raw, category: .unknown, term: nil, detail: nil,
                                            evidence: evidence, retired: false, ambiguity: nil, date: date)
            }
            return ClassifiedOccupation(raw: raw, category: rule.category, term: rule.term, detail: rule.detail,
                                        evidence: evidence, retired: retired && rule.category != .status,
                                        ambiguity: rule.ambiguity, date: date)
        }

        /// Explicit occupation cues in a note → classified fragments. Only
        /// the words right after a cue are read, and only when they classify
        /// as a real occupation.
        public static func fromNote(_ note: String) -> [ClassifiedOccupation] {
            let lowered = note.lowercased()
            let cues = ["worked as a ", "worked as an ", "worked as ", "employed as a ", "employed as an ",
                        "employed as ", "occupation: ", "occupation was ", "occupation - ", "occupation ",
                        "by trade a ", "by trade an ", "by trade ", "trade: ", "profession: ",
                        "was a professional ", "earned his living as a ", "earned her living as a "]
            var out: [ClassifiedOccupation] = []
            // Cues are listed longest-first; one cue position is read once
            // ("worked as a " and "worked as " start at the same place).
            var usedStarts = Set<String.Index>()
            var seen = Set<String>()
            for cue in cues {
                var searchStart = lowered.startIndex
                while let r = lowered.range(of: cue, range: searchStart..<lowered.endIndex) {
                    searchStart = r.upperBound
                    guard usedStarts.insert(r.lowerBound).inserted else { continue }
                    let tail = lowered[r.upperBound...]
                    let end = tail.firstIndex(where: { ".,;:()\n".contains($0) }) ?? tail.endIndex
                    let words = tail[..<end].split(separator: " ").prefix(4).joined(separator: " ")
                    guard !words.isEmpty, seen.insert(words).inserted else { continue }
                    let c = classify(words, evidence: .note)
                    if c.isOccupation { out.append(c) }
                }
            }
            return out
        }

        // MARK: Tokens

        static func tokenize(_ raw: String) -> [String] {
            let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            var tokens: [String] = []
            var current = ""
            for ch in folded {
                if ch.isLetter { current.append(ch) }
                else if !current.isEmpty { tokens.append(current); current = "" }
            }
            if !current.isEmpty { tokens.append(current) }
            // "farm-labourer" / "farmlabourer" stay as written; plurals are
            // in the table where they occur.
            return tokens
        }

        // MARK: Table

        /// `rules` grouped by first token, table order kept within a group.
        static let rulesByFirstToken: [String: [Rule]] = Dictionary(grouping: rules) { $0.tokens.first ?? "" }

        static let rules: [Rule] = {
            var r: [Rule] = []
            func add(_ category: OccupationCategory, _ term: String, _ phrases: [String],
                     detail: String? = nil, ambiguity: String? = nil) {
                for p in phrases {
                    r.append(Rule(tokens: p.split(separator: " ").map(String.init), category: category,
                                  term: term, detail: detail, ambiguity: ambiguity))
                }
            }
            // Status words — not occupations.
            add(.status, "spinster", ["spinster", "spr"])
            add(.status, "widow", ["widow", "widower", "wid", "relict"])
            add(.status, "gentleman", ["gentleman", "gent", "gentlewoman", "esquire", "esq", "lady"])
            add(.status, "scholar", ["scholar", "student", "school", "pupil", "at school"])
            add(.status, "pauper", ["pauper", "inmate", "almsman", "almswoman", "parish relief"])
            add(.status, "of independent means", ["annuitant", "independent", "own means", "living on own means",
                                                  "income from property", "fundholder", "proprietor of houses",
                                                  "landowner", "landed proprietor", "of independent means", "private means"])
            add(.status, "retired", ["retired", "pensioner", "none", "no occupation", "unemployed", "invalid"])
            add(.status, "wife", ["wife", "wife of", "daughter", "son", "infant", "child", "bachelor"])
            // Home duties.
            add(.homeDuties, "housewife", ["housewife", "keeping house", "keeps house", "home duties",
                                           "homemaker", "house wife", "at home", "household duties", "domestic duties"])
            // Labourers / manual work.
            add(.labourer, "labourer", ["labourer", "laborer", "labourers", "laborers", "labr", "lab", "labouring",
                                        "laboring", "labouring man", "general labourer", "gen lab",
                                        "day labourer", "day laborer", "workman", "navvy", "hod carrier",
                                        "ditcher", "hedger", "road labourer", "roadman", "porter",
                                        "factory hand", "factory worker", "mill hand", "mill worker", "mill operative",
                                        "operative", "mill girl", "dock labourer", "docker", "stevedore",
                                        "longshoreman", "coal heaver", "carter", "carman", "teamster", "drover",
                                        "ostler", "hostler", "stableman", "platelayer", "railway labourer",
                                        "fireman stoker", "railway fireman", "stoker", "driver", "truck driver", "chauffeur",
                                        "janitor", "watchman", "quarryman", "quarrier", "brickmaker", "sawyer",
                                        "packer", "warehouseman", "shoveller", "scavenger", "chimney sweep", "sweep"])
            add(.labourer, "agricultural labourer", ["ag lab", "ag labourer", "ag laborer", "agricultural labourer",
                                                     "agricultural laborer", "agr lab", "agric lab", "farm labourer",
                                                     "farm laborer", "farm lab", "farm hand", "farmhand",
                                                     "farm worker", "farm servant", "plowman", "ploughman",
                                                     "cottager", "thresher", "harvester"],
                detail: "agricultural")
            add(.labourer, "miner", ["miner", "coal miner", "collier", "pitman", "hewer", "mine worker",
                                     "coal hewer", "lead miner", "tin miner", "copper miner"], detail: "mining")
            // Trades and crafts.
            add(.trades, "carpenter", ["carpenter", "carp", "joiner", "cabinet maker", "cabinetmaker", "housewright"])
            add(.trades, "blacksmith", ["blacksmith", "smith", "blksmith", "farrier", "whitesmith", "tinsmith",
                                        "tinner", "tinman", "coppersmith", "locksmith", "gunsmith", "nailer",
                                        "nail maker", "ironworker", "iron worker"])
            add(.trades, "mason", ["mason", "stonemason", "stone mason", "bricklayer", "brick layer", "plasterer",
                                   "slater", "thatcher", "glazier", "plumber", "builder", "stone cutter",
                                   "stonecutter", "paver", "tiler"])
            add(.trades, "shoemaker", ["shoemaker", "shoe maker", "cordwainer", "bootmaker", "boot maker",
                                       "cobbler", "shoemkr", "currier", "tanner", "saddler", "harness maker",
                                       "leather worker"])
            add(.trades, "tailor", ["tailor", "tailoress", "dressmaker", "dress maker", "seamstress", "sempstress",
                                    "milliner", "needlewoman", "upholsterer", "hatter", "glover"])
            add(.trades, "weaver", ["weaver", "handloom weaver", "spinner", "cotton spinner", "flax spinner",
                                    "wool comber", "woolcomber", "fuller", "dyer", "linen weaver",
                                    "silk weaver", "lace maker", "knitter", "carder"], detail: "textile")
            add(.trades, "cooper", ["cooper", "wheelwright", "cartwright", "wainwright", "millwright",
                                    "turner", "chair maker", "basket maker", "rope maker", "ropemaker",
                                    "sailmaker", "sail maker", "coachbuilder", "coach builder", "shipwright",
                                    "ship carpenter", "ships carpenter", "boat builder"])
            add(.trades, "baker", ["baker", "butcher", "miller", "brewer", "maltster", "confectioner",
                                   "distiller", "cheesemaker", "cheese maker"], detail: "food")
            add(.trades, "mechanic", ["mechanic", "machinist", "engine fitter", "fitter", "boilermaker",
                                      "boiler maker", "electrician", "toolmaker", "tool maker", "moulder",
                                      "molder", "pattern maker", "welder", "engine driver",
                                      "locomotive engineer", "engineman", "lineman", "telegraph operator"])
            add(.trades, "watchmaker", ["watchmaker", "watch maker", "clockmaker", "clock maker", "jeweller",
                                        "jeweler", "goldsmith", "silversmith", "potter", "glassblower",
                                        "glass blower", "pewterer", "brazier", "chandler", "tallow chandler",
                                        "soap maker", "candle maker"])
            add(.trades, "painter", ["painter", "house painter", "painter and decorator", "decorator",
                                     "paperhanger", "paper hanger", "sign painter", "coach painter"],
                ambiguity: "a bare 'painter' in a record is usually a house painter; could be an artist")
            // Farming.
            add(.farming, "farmer", ["farmer", "farmers", "farming", "yeoman", "husbandman", "husbandry",
                                     "planter", "grazier", "cottier", "cottar", "crofter", "dairyman",
                                     "dairy farmer", "shepherd", "herdsman", "cowman", "agriculturist",
                                     "agriculturalist", "landholder", "tenant farmer", "rancher",
                                     "farm manager", "farm bailiff", "bailiff", "market gardener",
                                     "gardener", "nurseryman", "smallholder", "farmers son", "farmer s son",
                                     "farmers daughter", "fruit grower", "orchardist", "planter s son"])
            // Domestic service.
            add(.domesticService, "servant", ["servant", "serv", "servt", "svt", "domestic", "domestic servant",
                                              "dom serv", "gen serv", "general servant", "maid", "housemaid",
                                              "house maid", "kitchen maid", "kitchenmaid", "parlour maid",
                                              "parlourmaid", "ladys maid", "lady s maid", "nursemaid",
                                              "nurse maid", "maid servant", "maidservant", "cook", "cook domestic",
                                              "housekeeper", "house keeper", "butler", "footman", "valet",
                                              "groom", "coachman", "laundress", "washerwoman", "washer woman",
                                              "charwoman", "char woman", "hired girl", "hired man", "page",
                                              "scullery maid", "between maid", "lady s companion", "companion"])
            // Military.
            add(.military, "soldier", ["soldier", "private", "pte", "corporal", "cpl", "sergeant", "serjeant",
                                       "sgt", "lance corporal", "lieutenant", "lieut", "lt", "major",
                                       "colonel", "col", "general officer", "army", "army officer",
                                       "militia", "militiaman", "regiment", "rifleman", "gunner", "sapper",
                                       "trooper", "dragoon", "fusilier", "grenadier", "artilleryman",
                                       "chelsea pensioner", "army pensioner", "marine", "royal marines",
                                       "us army", "british army", "infantry", "cavalry", "officer in the army",
                                       "drummer", "bombardier", "quartermaster"])
            add(.military, "sailor (navy)", ["royal navy", "navy", "naval officer", "us navy", "bluejacket",
                                             "able seaman royal navy", "petty officer", "midshipman"],
                detail: "navy")
            // Clergy.
            add(.clergy, "clergyman", ["clergyman", "clergy", "clerk in holy orders", "minister", "priest",
                                       "vicar", "rector", "curate", "pastor", "reverend", "rev", "deacon",
                                       "nun", "religious sister", "sister of mercy", "preacher",
                                       "missionary", "bishop", "chaplain", "parson", "evangelist", "monk",
                                       "friar", "minister of the gospel", "methodist minister",
                                       "congregational minister", "presbyterian minister", "catholic priest"])
            // Professions.
            add(.professions, "lawyer", ["lawyer", "attorney", "attorney at law", "solicitor", "barrister",
                                         "judge", "justice", "counsellor at law", "counselor at law",
                                         "notary", "notary public", "law clerk", "conveyancer"], detail: "law")
            add(.professions, "physician", ["physician", "doctor", "dr", "surgeon", "apothecary", "dentist",
                                            "medical doctor", "general practitioner", "md", "nurse",
                                            "trained nurse", "registered nurse", "hospital nurse", "midwife",
                                            "pharmacist", "druggist", "chemist and druggist", "veterinary surgeon",
                                            "veterinarian", "optician"], detail: "medicine")
            add(.professions, "teacher", ["teacher", "school teacher", "schoolteacher", "schoolmaster",
                                          "school master", "schoolmistress", "school mistress", "professor",
                                          "lecturer", "tutor", "governess", "principal", "headmaster",
                                          "headmistress", "instructor", "educator", "pupil teacher"],
                detail: "teaching")
            add(.professions, "engineer", ["engineer", "civil engineer", "architect", "surveyor", "land surveyor",
                                           "accountant", "chartered accountant", "chemist", "scientist",
                                           "draughtsman", "draftsman", "actuary", "librarian"], detail: "other")
            // Arts.
            add(.arts, "artist", ["artist", "portrait painter", "landscape painter", "painter artist",
                                  "artist painter", "painter in oils", "fine artist", "sculptor", "illustrator",
                                  "engraver", "etcher", "lithographer", "photographer", "designer",
                                  "art teacher", "miniature painter", "cartoonist"], detail: "visual art")
            add(.arts, "musician", ["musician", "music teacher", "teacher of music", "professor of music",
                                    "organist", "pianist", "violinist", "fiddler", "piper", "singer",
                                    "vocalist", "composer", "bandmaster", "band master", "choirmaster",
                                    "conductor of music", "music hall artiste", "orchestra"], detail: "music")
            add(.arts, "actor", ["actor", "actress", "comedian", "comedienne", "dancer", "entertainer",
                                 "performer", "artiste", "theatrical", "stage manager", "showman", "circus",
                                 "vaudeville", "film actor"], detail: "stage")
            // Writing and the print trade.
            add(.writing, "author", ["author", "writer", "poet", "novelist", "playwright", "dramatist",
                                     "essayist", "historian", "author and journalist"], detail: "writing")
            add(.writing, "journalist", ["journalist", "reporter", "editor", "newspaper editor",
                                         "newspaper reporter", "correspondent", "columnist", "newspaperman",
                                         "news editor", "sub editor"], detail: "journalism")
            add(.writing, "printer", ["printer", "compositor", "typesetter", "type setter", "pressman",
                                      "printer s apprentice", "printers apprentice", "bookbinder",
                                      "book binder", "publisher", "stereotyper", "linotype operator",
                                      "proof reader", "proofreader"], detail: "print trade")
            // Business and trade.
            add(.business, "merchant", ["merchant", "shopkeeper", "shop keeper", "storekeeper", "store keeper",
                                        "grocer", "draper", "linen draper", "haberdasher", "ironmonger merchant",
                                        "dealer", "trader", "ironmonger", "private secretary", "sales representative", "pedlar", "peddler", "hawker", "huckster",
                                        "salesman", "saleswoman", "commercial traveller", "traveling salesman",
                                        "manufacturer", "mill owner", "banker", "broker", "stockbroker",
                                        "insurance agent", "agent", "real estate agent", "contractor",
                                        "merchant tailor", "wholesaler", "retailer", "provision dealer",
                                        "tobacconist", "stationer", "bookseller", "jobber", "importer",
                                        "fishmonger", "greengrocer", "costermonger", "victualler",
                                        "licensed victualler", "publican", "innkeeper", "inn keeper",
                                        "hotel keeper", "hotelkeeper", "tavern keeper", "saloon keeper",
                                        "saloonkeeper", "bartender", "barman", "barmaid", "spirit dealer",
                                        "clerk", "bookkeeper", "book keeper", "cashier", "office clerk",
                                        "commercial clerk", "secretary", "typist", "stenographer"])
            // Maritime.
            add(.maritime, "mariner", ["mariner", "master mariner", "sailor", "seaman", "seafarer", "able seaman",
                                       "ordinary seaman", "sea captain", "ship master", "shipmaster",
                                       "master of vessel", "ship s mate", "mate", "boatman", "waterman",
                                       "lighterman", "bargeman", "whaler", "whaleman", "fisherman",
                                       "fishermen", "fisher", "pilot", "harbour pilot", "harbor pilot",
                                       "ferryman", "deckhand", "deck hand", "ship steward", "steward"])
            // Government and public service.
            add(.government, "public servant", ["postman", "postmaster", "postmistress", "letter carrier",
                                                "mail carrier", "post office clerk", "policeman", "police officer",
                                                "police constable", "constable", "patrolman", "detective",
                                                "customs officer", "customs", "excise officer", "exciseman",
                                                "revenue officer", "tax collector", "collector of customs",
                                                "civil servant", "government clerk", "town clerk", "selectman",
                                                "mayor", "justice of the peace", "magistrate", "sheriff",
                                                "deputy sheriff", "jailer", "gaoler", "prison warder",
                                                "warder", "coastguard", "coast guard", "fireman", "firefighter",
                                                "legislator", "member of parliament", "senator", "congressman",
                                                "representative", "inspector", "registrar", "census enumerator",
                                                "lighthouse keeper", "relieving officer"])
            return r
        }()
    }

    /// Classify everything one subject records: OCCU values first, then
    /// note cues (de-duplicated by term against the OCCU values).
    public static func occupations(of subject: Subject) -> [ClassifiedOccupation] {
        var out = subject.occupations.map {
            OccupationClassifier.classify($0.value, evidence: .occupationTag, date: $0.date)
        }
        let terms = Set(out.compactMap(\.term))
        for note in subject.notes {
            for c in OccupationClassifier.fromNote(note) where !terms.contains(c.term ?? "") {
                if !out.contains(where: { $0.term == c.term && $0.evidence == .note }) { out.append(c) }
            }
        }
        return out
    }
}
