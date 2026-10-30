import Foundation
import Testing
@testable import VideoScan

// MARK: - HalliePronunciationRespelling.respelling(for:hint:) — characterization
//
// Written 2026-10-29 BEFORE the CCN 32 function was split into one helper
// per hint kind. One row per hint branch (and its refusals), each pinned
// to what the unchanged function returned. Pure: no lexicon file, no I/O
// (the default gold lexicon is `.empty`). Green before and after.
// A nil row is a refusal the unchanged function made (no such vowel or
// syllable, unknown exemplar, a first letter "silent", rhymes, empty name).

@Suite("Hallie pronunciation respelling — characterization")
struct HalliePronunciationRespellingCharacterizationTests {

    private typealias R = HalliePronunciationRespelling
    private typealias H = HalliePronunciationHint

    @Test func respellingForEachHintKind() {
        let cases: [(String, H, String?)] = [
            ("Latta", .stress(.first), "LAT-uh"),
            ("Latta", .stress(.last), "lat-A"),
            ("Nathaniel", .stress(.third), "na-tha-NIEL"),
            ("Edith", .stress(.third), "e-DITH"),
            ("Nathaniel", .vowel(letter: "a", length: .short, syllable: nil), "NAT-ha-niel"),
            ("Peter", .vowel(letter: "e", length: .long, syllable: nil), "PEE-ter"),
            ("Lida", .vowel(letter: "i", length: .long, syllable: nil), "LEYE-duh"),
            ("Rosa", .vowel(letter: "o", length: .long, syllable: nil), "ROH-suh"),
            ("Ruth", .vowel(letter: "u", length: .long, syllable: nil), "ROOTH"),
            ("Latta", .vowel(letter: "a", length: .long, syllable: "ta"), nil),
            ("Latta", .vowel(letter: "o", length: .short, syllable: nil), nil),
            ("Latta", .vowelLike(letter: "a", exemplar: "cat"), "LAT-uh"),
            ("Latta", .vowelLike(letter: "a", exemplar: "cake"), "LAY-tuh"),
            ("Latta", .vowelLike(letter: "a", exemplar: "father"), "LAHT-uh"),
            ("Latta", .vowelLike(letter: "a", exemplar: "zzqx"), nil),
            ("Latta", .vowelLike(letter: "o", exemplar: "father"), nil),
            ("Knapp", .silent("k"), nil),
            ("Knight", .silent("g"), "KNIHT"),
            ("Latta", .silent("z"), nil),
            ("George", .softG, "JEOR-je"),
            ("Gibson", .hardG, "GHIB-son"),
            ("Geller", .hardG, "GHEL-er"),
            ("Latta", .softG, "LAT-uh"),
            ("Latta", .syllables([.init(text: "La", exemplar: nil), .init(text: "Tah", exemplar: "spa")]), "la-TAH"),
            ("Latta", .syllables([.init(text: "LA", exemplar: nil)]), "LA"),
            ("Latta", .rhymes(with: "data"), nil),
            ("", .stress(.first), nil),
            ("1234", .softG, nil),
        ]
        for (index, (name, hint, want)) in cases.enumerated() {
            #expect(R.respelling(for: name, hint: hint) == want,
                    Comment(rawValue: "row \(index): \(name)"))
        }
    }
}
