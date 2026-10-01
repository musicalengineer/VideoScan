// FamilyMapFlag.swift (VideoScanCore/FamilyMap)
// GH #229 (family map design §5 stage 4): the tiny country flag on a
// Family Tree person card. The flag is DERIVED from the same unit key the
// map shades — "eng-yorkshire" and "eng" both fly England's flag — so a
// card and the map can never disagree about where someone was born.
//
// TODAY'S FLAGS, HONESTLY LABELLED. A 1650 Massachusetts Bay birth flies
// 🇺🇸, a 1904 Cork birth flies 🇮🇪 and an 1850 Prussian birth flies 🇩🇪:
// the flag is the country as the map draws it now, not the polity of the
// day (the card's tooltip says so — "Born in Prussia · shown under today's
// flag"). Northern Ireland has no subdivision emoji, so it flies the Union
// flag; England, Scotland and Wales have theirs.
//
// The flags are written as Unicode scalar escapes rather than pasted
// glyphs: a tag-sequence flag is seven invisible-looking code points, and
// an editor that "helpfully" normalises one would silently turn Scotland
// into a plain black flag. A national flag is two "regional indicator"
// letters (U+1F1E6 = A … U+1F1FF = Z) spelling the ISO 3166-1 alpha-2 code;
// `regionalIndicators("FR")` builds that pair. (C++ readers: `enum
// FamilyMapFlag` with no cases is a namespace; `\u{…}` is the same escape
// as C++'s `\U…`.)

import Foundation

public enum FamilyMapFlag {

    /// The emoji flag for a country under today's borders.
    public static func emoji(for country: FamilyMap.Country) -> String {
        switch country {
        case .england:
            // 🏴 + tag letters "gbeng" + cancel tag.
            return "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        case .scotland:
            // 🏴 + "gbsct" + cancel tag.
            return "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"
        case .wales:
            // 🏴 + "gbwls" + cancel tag.
            return "\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}"
        case .northernIreland:
            // No NI subdivision flag exists in Unicode: the UK flag (G B).
            return "\u{1F1EC}\u{1F1E7}"
        case .ireland:
            return "\u{1F1EE}\u{1F1EA}"          // I E
        case .unitedStates:
            return "\u{1F1FA}\u{1F1F8}"          // U S
        case .canada:
            return "\u{1F1E8}\u{1F1E6}"          // C A
        case .france: return regionalIndicators("FR")
        case .germany: return regionalIndicators("DE")
        case .netherlands: return regionalIndicators("NL")
        case .belgium: return regionalIndicators("BE")
        case .luxembourg: return regionalIndicators("LU")
        case .switzerland: return regionalIndicators("CH")
        case .austria: return regionalIndicators("AT")
        case .denmark: return regionalIndicators("DK")
        case .norway: return regionalIndicators("NO")
        case .sweden: return regionalIndicators("SE")
        case .italy: return regionalIndicators("IT")
        case .spain: return regionalIndicators("ES")
        case .portugal: return regionalIndicators("PT")
        }
    }

    /// Two ASCII capitals → the regional-indicator pair that renders as
    /// that country's flag ("FR" → 🇫🇷). Only ever called with the literal
    /// codes above; anything that is not A–Z is dropped.
    static func regionalIndicators(_ alpha2: String) -> String {
        var out = String.UnicodeScalarView()
        for v in alpha2.unicodeScalars.map(\.value) where v >= 0x41 && v <= 0x5A {
            if let s = Unicode.Scalar(0x1F1E6 + (v - 0x41)) { out.append(s) }
        }
        return String(out)
    }

    /// The country a map unit key belongs to — "eng-yorkshire" and "eng"
    /// are both England; nil for nil, blank or a key of no country the
    /// map knows (an unresolved or off-map birth has no flag).
    public static func country(forUnitKey key: String?) -> FamilyMap.Country? {
        guard let key, !key.isEmpty else { return nil }
        return FamilyMapKey.country(of: key)
    }

    /// The flag for a unit key, or nil when the key has no country.
    public static func emoji(forUnitKey key: String?) -> String? {
        country(forUnitKey: key).map(emoji(for:))
    }
}

public extension FamilyMap.Country {
    /// This country's flag emoji (today's flag — see FamilyMapFlag).
    var flag: String { FamilyMapFlag.emoji(for: self) }
}
