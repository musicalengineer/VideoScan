// FamilyAssetIdentityDirectory.swift
// Who a group-photo folder's name tokens refer to (2026-08-26).
//
// Live miss: "tell me about richard harding breen sr" showed
// People/RickDonnaBreenFamily/SouthEastMontana1995.jpg — Rick, Donna and the
// boys — because `rick → richard` + surname `breen` fits Rick's father just
// as well as Rick. A folder token must resolve to ONE tree person, by the
// strongest evidence available, and a diminutive that several relatives
// share attaches to none of them.
//
// Evidence order, strongest first:
//   1. the owner's configured nickname ("Rick Breen" → "rick" = owner)
//   2. CyberBrain aliases ("Dick" = Richard Sr) and People-tab POI aliases
//   3. the tree's own given names, through the curated diminutives table
// A generational suffix in the folder ("…BreenSrFamily") narrows an
// otherwise ambiguous set. Every level is restricted to people who carry
// one of the folder's surnames (own or by marriage), so "DonnaBreen" still
// reaches Donna Hudson who married a Breen.
//
// C++ analogy: an immutable lookup table built once from the tree plus the
// alias sources, passed by value into FamilyAssetStore. Pure functions; no
// I/O; no evidence — photos stay presentation only.

import Foundation
import VideoScanCore

struct FamilyAssetIdentityDirectory: Sendable, Equatable {

    struct Member: Sendable, Equatable {
        let gedcomID: String
        /// Formal given-name tokens as the tree spells them ("richard",
        /// "harding"), lowercased/diacritic-folded, suffixes removed.
        let givenTokens: Set<String>
        /// Own surname plus every spouse's surname.
        let surnameTokens: Set<String>
        /// "jr" / "sr" / "ii" … when the tree name carries one.
        let suffix: String?
        /// Nickname tokens the tree does NOT already say ("rick", "dick",
        /// "dicky") from CyberBrain / POI aliases, or from the owner's
        /// configured name when this member is the owner.
        let aliasTokens: Set<String>
    }

    let members: [Member]
    let ownerGedcomID: String?
    /// Tokens of the owner's configured name that are nicknames (not the
    /// tree's formal given names): "Rick Breen" → {"rick"}.
    let ownerTokens: Set<String>

    private var byID: [String: Member] {
        Dictionary(members.map { ($0.gedcomID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    init(members: [Member], ownerGedcomID: String?, ownerTokens: Set<String> = []) {
        self.members = members
        self.ownerGedcomID = ownerGedcomID
        self.ownerTokens = ownerTokens
    }

    func member(_ gedcomID: String?) -> Member? {
        guard let gedcomID else { return nil }
        return byID[gedcomID]
    }

    // MARK: Building from live sources

    /// Alias spellings keyed by GEDCOM ID, from any source (CyberBrain
    /// people carrying a pointer, POI profiles matched by name).
    typealias AliasTable = [String: [String]]

    init(graph: GedcomFamilyGraph,
         speakers: HallieTurnExecutor.Speakers,
         cyberBrain: CyberBrainIndex? = nil,
         profiles: [HallieTurnExecutor.ProfileSnapshot]? = nil) {
        var aliases: AliasTable = [:]
        if let cyberBrain {
            for person in cyberBrain.archive.people {
                guard let pointer = person.gedcomPersonID, graph.people[pointer] != nil else { continue }
                aliases[pointer, default: []].append(contentsOf: [person.canonicalName] + person.aliases)
            }
        }
        for profile in profiles ?? [] {
            let matches = graph.people(matching: profile.canonicalName)
            guard matches.count == 1 else { continue }
            aliases[matches[0].id, default: []].append(contentsOf: profile.aliases)
        }
        let owner = Self.owner(in: graph, speakers: speakers, cyberBrain: cyberBrain)
        self.init(graph: graph, aliases: aliases, ownerGedcomID: owner?.id,
                  ownerName: speakers.ownerName)
    }

    /// The owner's tree record: FamilySearch ID pin, then a CyberBrain
    /// alias carrying a pointer, then the shared owner chain (name +
    /// tree root as tie-breaker) — the same ladder the kinship route uses.
    static func owner(in graph: GedcomFamilyGraph,
                      speakers: HallieTurnExecutor.Speakers,
                      cyberBrain: CyberBrainIndex?) -> GedcomFamilyGraph.Person? {
        if let pinned = graph.person(familySearchID: speakers.ownerFamilySearchID) { return pinned }
        // A configured ID the tree lacks fails closed (codex #707): no
        // CyberBrain / name / root fall-through can bind the wrong owner.
        if HallieOwnerResolver.stalePinLine(familySearchID: speakers.ownerFamilySearchID, graph: graph) != nil {
            return nil
        }
        guard let ownerName = speakers.ownerName else { return nil }
        if let cyberBrain, case .resolved(let person) = cyberBrain.resolve(ownerName),
           let pointer = person.gedcomPersonID, let tree = graph.people[pointer] {
            return tree
        }
        if case .one(let person, _) = HallieOwnerResolver.resolve(
            ownerName, graph: graph, familySearchID: speakers.ownerFamilySearchID) {
            return person
        }
        return nil
    }

    /// Pure builder: tree + alias table + owner. Tests use this directly.
    ///
    /// The tree pass (given / surname / suffix tokens per person, spouse
    /// surnames included) comes ready-made from the compiled index's
    /// launch tables (TreeIndex formatVersion 2, 2026-08-29) — no name is
    /// tokenized and no family unit is walked here. Members are assembled
    /// in parallel chunks of ordinals; ordinal order IS `gedcomID` order,
    /// so the result is the same sorted list the per-person walk produced
    /// (FamilyAssetIdentityDirectoryTests pins it against the frozen
    /// builder on the 39k synthetic tree).
    init(graph: GedcomFamilyGraph,
         aliases: AliasTable,
         ownerGedcomID: String?,
         ownerName: String?) {
        let suffixes = GedcomFamilyGraph.nameSuffixes
        let index = graph.index
        let keys = index.identityKeys
        // Pass 2: aliases contribute only what the tree does not already
        // say, so "Richard Harding Breen Sr" as an alias never lets Sr claim
        // "Richard" ahead of Jr — that stays a tree-level (ambiguous) match.
        // `identityKeys` is exactly every given + surname (+ used suffix)
        // token of the tree; subtracting it and the suffix table equals
        // the old `allGiven ∪ allSurnames ∪ suffixes` subtraction.
        let treeSaid = Set(keys)
        func nicknameTokens(_ spellings: [String]) -> Set<String> {
            Set(spellings.flatMap(Self.tokens)).subtracting(treeSaid).subtracting(suffixes)
        }
        let ownerNick = nicknameTokens(ownerName.map { [$0] } ?? [])
        let count = index.count
        let chunk = 4096
        let chunks = (count + chunk - 1) / chunk
        let members = [Member](unsafeUninitializedCapacity: count) { buffer, initialized in
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = c * chunk, hi = min(count, lo + chunk)
                for i in lo..<hi {
                    let o = Int32(i)
                    let id = index.ids[i]
                    var nick = nicknameTokens(aliases[id] ?? [])
                    if id == ownerGedcomID { nick.formUnion(ownerNick) }
                    let suffix = index.suffixIDs[i]
                    (buffer.baseAddress! + i).initialize(to: Member(
                        gedcomID: id,
                        givenTokens: Set(index.givenIDs(of: o).map { keys[Int($0)] }),
                        surnameTokens: Set(index.surnameTokenIDs(of: o).map { keys[Int($0)] }),
                        suffix: suffix < 0 ? nil : keys[Int(suffix)],
                        aliasTokens: nick))
                }
            }
            initialized = count
        }
        self.members = members
        self.ownerGedcomID = ownerGedcomID
        self.ownerTokens = ownerGedcomID == nil ? [] : ownerNick
    }

    // MARK: Attribution

    /// GEDCOM IDs a group folder's tokens attribute the photo to. Each
    /// non-surname token resolves independently; a token that fits several
    /// relatives attributes to nobody (unless a suffix token settles it).
    /// Surname-only folders ("Breen_Family") attribute to every carrier of
    /// that surname, as before.
    func attributedMembers(folderTokens: [String]) -> Set<String> {
        let suffixes = GedcomFamilyGraph.nameSuffixes
        let suffixTokens = Set(folderTokens.filter { suffixes.contains($0) })
        let nameTokens = folderTokens.filter { !suffixes.contains($0) }
        let folderSurnames = Set(nameTokens).intersection(
            members.reduce(into: Set<String>()) { $0.formUnion($1.surnameTokens) })
        guard !folderSurnames.isEmpty else { return [] }
        let family = members.filter { !$0.surnameTokens.isDisjoint(with: folderSurnames) }
        let givenTokens = nameTokens.filter { !folderSurnames.contains($0) }
        if givenTokens.isEmpty {
            return Set(family.map(\.gedcomID))
        }
        var out: Set<String> = []
        for token in givenTokens {
            if let one = resolve(token: token, suffixTokens: suffixTokens, among: family) {
                out.insert(one)
            }
        }
        return out
    }

    /// True when `gedcomID` is one of the people the folder names.
    func folderNames(_ gedcomID: String, folderTokens: [String]) -> Bool {
        attributedMembers(folderTokens: folderTokens).contains(gedcomID)
    }

    /// One token → one person, or nil. Strongest non-empty level wins;
    /// several candidates at that level is ambiguity, not a choice.
    private func resolve(token: String, suffixTokens: Set<String>,
                         among family: [Member]) -> String? {
        func formal(_ t: String) -> String { GedcomFamilyGraph.diminutives[t] ?? t }
        let levels: [[Member]] = [
            // 1. the owner's own nickname
            ownerTokens.contains(token)
                ? family.filter { $0.gedcomID == ownerGedcomID } : [],
            // 2. curated aliases (CyberBrain / People tab)
            family.filter { $0.aliasTokens.contains(token) },
            // 3. the tree's given names, diminutive-tolerant
            family.filter { member in
                member.givenTokens.contains(token)
                    || member.givenTokens.contains(where: { formal($0) == formal(token) })
            },
        ]
        guard var candidates = levels.first(where: { !$0.isEmpty }) else { return nil }
        if !suffixTokens.isEmpty {
            let narrowed = candidates.filter { $0.suffix.map(suffixTokens.contains) ?? false }
            if !narrowed.isEmpty { candidates = narrowed }
        }
        return candidates.count == 1 ? candidates[0].gedcomID : nil
    }

    static func tokens(_ value: String) -> [String] {
        FamilyIdentityText.tokens(value)
    }
}
