// GedcomSyntheticPedigree.swift (VideoScanCore)
// Deterministic synthetic GEDCOM text at production scale, for the scale
// sensors and perf benchmarks (2026-08-28, "melt silicon": tree search
// and kinship walks must feel instant on a ~40k-person merged tree).
//
// Shape mirrors a colonial New England pull: generations of a fixed
// population, every person's parents drawn from the generation above
// with a seeded PRNG, so ancestor sets overlap heavily (pedigree
// collapse) and lines run 20+ generations deep. Names come from small
// pools so token postings look like real data (hundreds of Johns, a few
// hundred distinct surnames). No real family data — names are stock.
//
// Lives in Sources (not Tests) so the app-target sensors and the core
// package tests share ONE generator; it is pure text and never runs in
// production paths.

import Foundation

public enum GedcomSyntheticPedigree {

    /// A seeded xorshift so every run sees the same tree.
    struct PRNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
    }

    static let givenNames: [String] = [
        "John", "Mary", "William", "Elizabeth", "Thomas", "Sarah", "Samuel", "Hannah",
        "Joseph", "Abigail", "Richard", "Martha", "Nathaniel", "Ann", "Ebenezer", "Ruth",
        "Benjamin", "Lydia", "Daniel", "Susanna", "Jonathan", "Rebecca", "Josiah", "Mercy",
        "Ezra", "Deborah", "Increase", "Patience", "Frederick", "Muriel", "George", "Edith",
        "Timothy", "Donna", "Robert", "Margaret", "James", "Jane", "Edward", "Catherine",
    ]
    static let surnames: [String] = [
        "Breen", "Lamb", "Latta", "McGill", "Hudson", "Stone", "Hill", "Adams", "Alden",
        "Bradford", "Brewster", "Standish", "Winslow", "Howland", "Warren", "Fuller",
        "Cooke", "Allerton", "Chilton", "Eaton", "Hopkins", "Mullins", "Priest", "Rogers",
        "Soule", "Tilley", "White", "Billington", "Doty", "Sampson", "Gorham", "Otis",
        "Bourne", "Freeman", "Sears", "Snow", "Crocker", "Hinckley", "Nickerson", "Ryder",
    ]

    /// `people` INDI records in `generations` rows (the last row is the
    /// root's generation, first in file order so `rootPersonID` is a
    /// young person with the deepest pedigree). Each row after the oldest
    /// hangs from families in the row above; `familiesPerRow` couples per
    /// row share the children (intermarriage). Roughly `people` INDI and
    /// `people / 3` FAM records; every person has a birth year.
    public static func gedcom(people: Int, generations: Int = 22, seed: UInt64 = 0x9E3779B97F4A7C15) -> String {
        precondition(people > 0 && generations > 0)
        var rng = PRNG(state: seed)
        let perRow = max(2, people / generations)
        var out: [String] = ["0 HEAD", "1 SOUR VideoScanSynthetic", "1 GEDC", "2 VERS 5.5.1"]
        out.reserveCapacity(people * 9)
        // Row r = generation r above the root (0 = youngest).
        // Person (r, i) → id. Families in row r+1 marry (r+1, a) M and (r+1, b) F.
        var families: [(id: String, husband: String, wife: String, children: [String])] = []
        var famsOf: [String: [String]] = [:]
        var famcOf: [String: String] = [:]
        var rowIDs: [[String]] = []
        var made = 0
        for r in 0..<generations {
            let count = r == generations - 1 ? people - made : min(perRow, people - made)
            guard count > 0 else { break }
            rowIDs.append((0..<count).map { "@I\(r)_\($0)@" })
            made += count
        }
        // Couples in row r+1: pair even-index (M) with a random odd-index (F)
        // of the same row; a person may appear in several families.
        for r in 0..<(rowIDs.count - 1) {
            let above = rowIDs[r + 1]
            let men = above.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
            let women = above.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
            guard !men.isEmpty, !women.isEmpty else { continue }
            let familyCount = max(1, above.count / 3)
            var rowFamilies: [Int] = []
            for f in 0..<familyCount {
                let id = "@F\(r + 1)_\(f)@"
                let h = men[rng.below(men.count)], w = women[rng.below(women.count)]
                families.append((id, h, w, []))
                famsOf[h, default: []].append(id)
                famsOf[w, default: []].append(id)
                rowFamilies.append(families.count - 1)
            }
            for child in rowIDs[r] {
                let fam = rowFamilies[rng.below(rowFamilies.count)]
                families[fam].children.append(child)
                famcOf[child] = families[fam].id
            }
        }
        for (r, ids) in rowIDs.enumerated() {
            let year = 2000 - 27 * r
            for (i, id) in ids.enumerated() {
                let given = givenNames[rng.below(givenNames.count)]
                let middle = rng.below(3) == 0 ? " " + givenNames[rng.below(givenNames.count)] : ""
                let surname = surnames[(i * 7 + r) % surnames.count]
                out.append("0 \(id) INDI")
                out.append("1 NAME \(given)\(middle) /\(surname)/")
                out.append("1 SEX \(i % 2 == 0 ? "M" : "F")")
                out.append("1 BIRT")
                out.append("2 DATE \(1 + rng.below(28)) JAN \(year - rng.below(5))")
                if rng.below(4) == 0 { out.append("2 PLAC Plymouth, Massachusetts, USA") }
                if let famc = famcOf[id] { out.append("1 FAMC \(famc)") }
                for fams in famsOf[id] ?? [] { out.append("1 FAMS \(fams)") }
                // Every 5th person carries a stable FamilySearch-style id.
                if i % 5 == 0 { out.append("1 _FSFTID \(fsid(r, i))") }
            }
        }
        for fam in families {
            out.append("0 \(fam.id) FAM")
            out.append("1 HUSB \(fam.husband)")
            out.append("1 WIFE \(fam.wife)")
            for c in fam.children { out.append("1 CHIL \(c)") }
        }
        out.append("0 TRLR")
        return out.joined(separator: "\n")
    }

    /// "AAAA-000"-shaped id, unique per (row, slot).
    static func fsid(_ r: Int, _ i: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var n = r * 100_000 + i
        var letters = ""
        for _ in 0..<4 { letters.append(alphabet[n % 26]); n /= 26 }
        return letters + "-" + String(format: "%03d", (r * 100_000 + i) % 1000)
    }
}
