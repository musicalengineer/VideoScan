// AvidPairEvidence.swift
// THE rule for pairing an Avid MXF video with an audio file (Rick
// 2026-10-22: "find matching pair fails to find the correct sequence…
// broken"). One pure function, read by every pair-forming and pair-keeping
// site: CorrelationScorer.scoreCorrelatePair (→ findBestPair, Find A/V
// Pair), CorrelationScorer.assignPairs (bulk Correlate),
// Correlator.scoreCandidate, MissingAudioFinder's "Correlate will accept"
// prediction, and CorrelationScorer.persistedPairIsValid (stored pairs at
// load / after Fill In Avid IDs). NOT the cross-volume clip-ID pass
// (assignAvidPairs): it pairs only `NNNNN.V<hex>.mxf` ↔ `NNNNN.A<hex>.mxf`
// with the SAME hex — Avid's own mob-ID naming, an identity, not a
// heuristic — and a render's name never has that shape.
//
// The evidence (verified with ffprobe on Rick's drives, 3,699 live MXF rows):
//   • Every file of one Avid clip carries the clip's `material_package_name`
//     — A1, A2 and the V, even when a consolidate / transcode re-minted the
//     V's UMID (clip 00002: A1/A2 UMID …4B9428E6…, V UMID …4D1BBD84…, all
//     named "00002"). Avid appends `.new.NN` to the name on each
//     consolidate, and V and A may carry different counters ("00045.new.03"
//     / "00045.new.02"), so names compare with that suffix removed.
//   • A1 and A2 of one capture share a UMID; equal UMIDs are the same clip.
//   • Renders / precomputes (effects, titles, mixdowns: `Boston.Sequence
//     updated.03,Title,13`) are video-only by design and have NO partner.
//
// The rule, when the video is an MXF:
//   1. a render (either side) never pairs;
//   2. the partner must be an MXF;
//   3. pair only when the UMIDs are equal, or the clip names are equal;
//   4. otherwise no NEW pair — no fallback to duration / filename heuristics.
// A STORED pair is released only on POSITIVE evidence that it is wrong —
// rules 1, 2, or two names present that differ. A missing ID keeps it.
// Non-MXF videos keep today's scoring unchanged (`.notAvid`).
//
// (For Rick: `AvidPairSide` is a small POD copied off the record so the
// rule can run on any thread; `Verdict` is a tagged union — std::variant —
// whose payload is the reason in words for the log.)

import Foundation
import VideoScanCore

/// The facts the rule reads about one side of a pair.
struct AvidPairSide: Sendable, Equatable {
    let filename: String
    let isMXF: Bool
    let umid: String
    let clipName: String
    let isRender: Bool

    init(filename: String, container: String = "", umid: String = "", name: String = "", isRender: Bool = false) {
        self.filename = filename
        self.isMXF = Self.isMXF(filename: filename, container: container)
        self.umid = umid.trimmingCharacters(in: .whitespaces)
        self.clipName = AvidNameKey.normalized(name)
        self.isRender = isRender
    }

    init(_ r: VideoRecord) {
        self.init(filename: r.filename, container: r.container, umid: r.materialPackageUMID,
                  name: r.materialPackageName, isRender: r.isAvidRender)
    }

    /// An MXF by name or by what ffprobe called its container — an
    /// extensionless Logic sample ("KONTBSTR1X32") is not one.
    static func isMXF(filename: String, container: String) -> Bool {
        (filename as NSString).pathExtension.lowercased() == "mxf" || container.uppercased().hasPrefix("MXF")
    }
}

/// Avid clip names, compared with the consolidate counter removed.
enum AvidNameKey {
    /// "00045.new.03" → "00045"; "AllVideosStereo,Audio Dissolve,2.new.01"
    /// → "AllVideosStereo,Audio Dissolve,2"; "" stays "".
    static func normalized(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while let r = n.range(of: #"\.new\.\d+$"#, options: .regularExpression) {
            n.removeSubrange(r)
        }
        return n
    }
}

enum AvidPairEvidence {

    enum Verdict: Equatable, Sendable {
        /// The video is not an MXF: today's scoring decides, unchanged.
        case notAvid
        /// Same clip (equal UMID, or equal clip name) — may pair.
        case sameClip(String)
        /// Positive evidence the two are NOT one clip: never pair, and a
        /// stored pair is released.
        case different(String)
        /// An MXF video with no shared Avid ID: no new pair; a stored one
        /// is kept.
        case unproven(String)
    }

    /// The one decision. Pure; O(1).
    static func judge(video v: AvidPairSide, audio a: AvidPairSide) -> Verdict {
        if v.isRender { return .different("\(v.filename) is an Avid render — a render has no audio partner") }
        if a.isRender { return .different("\(a.filename) is an Avid render — a render has no partner") }
        guard v.isMXF else { return .notAvid }
        guard a.isMXF else { return .different("an Avid MXF video's sound is always an MXF; \(a.filename) is not one") }
        if !v.umid.isEmpty, v.umid == a.umid { return .sameClip("same Avid UMID") }
        if !v.clipName.isEmpty, !a.clipName.isEmpty {
            return v.clipName == a.clipName
                ? .sameClip("same Avid clip name \"\(v.clipName)\"")
                : .different("different Avid clips — \"\(v.clipName)\" and \"\(a.clipName)\"")
        }
        return .unproven("no shared Avid ID yet (Fill In Avid IDs reads them)")
    }

    /// May a NEW pair be formed? Today's scoring for non-MXF; identity only
    /// for an Avid MXF video.
    static func permitsNewPair(video: AvidPairSide, audio: AvidPairSide) -> Bool {
        switch judge(video: video, audio: audio) {
        case .notAvid, .sameClip: return true
        case .different, .unproven: return false
        }
    }

    /// Why a STORED pair must be released; nil = keep it.
    static func releaseReason(video: AvidPairSide, audio: AvidPairSide) -> String? {
        if case .different(let why) = judge(video: video, audio: audio) { return why }
        return nil
    }
}

/// Is an MXF an Avid render / precompute? Two signals, either suffices:
///   • the material package name has Avid's render shape
///     `<sequence>,<effect>,<n>` ("Boston.Sequence updated.03,Title,13",
///     "MiscKids,Soft Sky,9", "AllVideosStereo.Exported.01,Video Mixdown,1")
///     — 140 of 3,264 named MXFs on Rick's drives, every one a render,
///     mixdown or effect, no ordinary clip;
///   • the header names the "Precompute Source Mob" (UTF-16BE, as Avid
///     writes strings) — catches the 8 renders ffprobe gives no name for.
/// Media Composer 2.x renders that ffprobe cannot read at all and whose
/// header lacks the marker are NOT detected (see the report).
enum AvidRenderSignal {

    static func nameLooksLikeRender(_ name: String) -> Bool {
        let n = AvidNameKey.normalized(name)
        return n.range(of: #"^.+,[^,]+,\d+$"#, options: .regularExpression) != nil
    }

    /// "Precompute Source Mob" as UTF-16 big-endian bytes.
    static let precomputeMarker: [UInt8] = Array("Precompute Source Mob".utf16).flatMap {
        [UInt8($0 >> 8), UInt8($0 & 0xFF)]
    }

    /// Does this header buffer carry the precompute marker? Pure.
    static func headerHasPrecomputeMarker(_ header: Data) -> Bool {
        let marker = precomputeMarker
        guard header.count >= marker.count else { return false }
        return header.withUnsafeBytes { raw -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            let last = bytes.count - marker.count
            var i = 0
            while i <= last {
                if bytes[i] == marker[0], bytes[i + 1] == marker[1] {
                    var k = 2
                    while k < marker.count, bytes[i + k] == marker[k] { k += 1 }
                    if k == marker.count { return true }
                }
                i += 1
            }
            return false
        }
    }

    static func isRender(name: String, header: Data?) -> Bool {
        nameLooksLikeRender(name) || header.map(headerHasPrecomputeMarker) == true
    }

    /// The first 256 KB of an MXF (where Avid's header metadata lives),
    /// read-only with read(2) like MxfHeaderParser — never mmap. nil when
    /// the file cannot be opened.
    static func readHeader(path: String, limit: Int = 256 * 1024) -> Data? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = Data(count: limit)
        let n = buf.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.read(fd, base, limit)
        }
        guard n > 0 else { return nil }
        return buf.prefix(n)
    }
}
