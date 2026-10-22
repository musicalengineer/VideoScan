// CompareMediaView.swift
// Compare Media, step 1 of the view (docs/design/event_analyzer_compare_media_2026_10_15.md §2):
// the verdict band, the evidence lines, the recommendation, and the two
// sound spools — drawn from last night's fingerprints — above the
// existing pair-compare detail (streams table, tiers). The next-face
// buttons come next (§3).
//
//   ┌ SAME EVENT · 37:30 of 38:00 · at 0:12 ──────────────────────┐  the band
//   │ Two transfers of one recording.                              │
//   │ ● Sound: 99 % … ● Same day … ○ Different bytes …             │  the lines
//   │ Master is archived in the better transfer. Remove …  [door]  │
//   └──────────────────────────────────────────────────────────────┘
//   ┌ name A ─────────┐   ┌ name B ─────────┐
//   │ facts, diffs in │   │ facts …         │
//   │ the accent      │   │                 │
//   │ ▣▣▣▣▣▣▣▣ frames │   │ ▣▣▣▣▣▣▣▣        │  same fractions both sides
//   │ ▌sound strip    │   │ ▌sound strip    │  green = matched
//   └─────────────────┘   └─────────────────┘
//   ■ green = same sound in both · ■ orange … · ■ grey = silence      the legend
//
// The frames (CompareFilmstrip.swift, 2026-10-22) load lazily, one loader
// per card, inside each card's `.task` — cancelled when the view goes.
//
// Byte-identical pair (Rick 2026-10-22): when the ladder's identicalCopy
// rung fired, the strips paint every audible second green — the sound IS
// the same, the bytes say so — and a short note says the fingerprint is
// stale when its stored match left audible seconds out (SoundStripPaint).
//
// PERF: the answer is computed once per pair in the store's task (the
// projection on the main actor, the match off it) and cached, with the
// strips' paint; the view reads values. Nothing in a body touches the
// catalog or the disk.

import Combine
import SwiftUI
import VideoScanCore

@MainActor
final class CompareMediaStore: ObservableObject {
    @Published private(set) var answer: RelatedAnswer?
    /// What each strip paints — derived from the answer once, here, so the
    /// body never walks a per-second map to decide colours.
    @Published private(set) var paintA: SoundStripPaint?
    @Published private(set) var paintB: SoundStripPaint?
    @Published private(set) var isWorking = false
    private var task: Task<Void, Never>?

    func load(model: VideoScanModel, a: VideoRecord, b: VideoRecord) {
        guard task == nil else { return }
        isWorking = true
        task = Task { [weak self] in
            let answer = await model.relatedAnswer(a: a, b: b)
            guard let self, !Task.isCancelled else { return }
            let identical = answer.verdict.isIdenticalCopy
            self.paintA = answer.strips.a.map {
                SoundStripPaint(active: $0, matched: answer.strips.matchedA,
                                durationSeconds: answer.evidence.a.durationSeconds, identicalBytes: identical)
            }
            self.paintB = answer.strips.b.map {
                SoundStripPaint(active: $0, matched: answer.strips.matchedB,
                                durationSeconds: answer.evidence.b.durationSeconds, identicalBytes: identical)
            }
            self.answer = answer
            self.isWorking = false
        }
    }

    deinit { task?.cancel() }
}

struct CompareMediaView: View {
    let recordA: VideoRecord
    let recordB: VideoRecord
    /// Forwarded ONCE into the store's load (the projection runs there,
    /// never in this body) and into the frame loaders' tasks (its
    /// thumbnail cache); the body reads only cached values.
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject private var model: VideoScanModel
    @StateObject private var store = CompareMediaStore()
    // `@StateObject` ≈ a member the framework owns for the view's lifetime
    // (the struct itself is rebuilt on every render; this is not).
    @StateObject private var framesA = CompareFilmstripLoader()
    @StateObject private var framesB = CompareFilmstripLoader()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let answer = store.answer {
                verdictCard(answer)
                HStack(alignment: .top, spacing: 12) {
                    spool(recordA, side: answer.evidence.a, other: answer.evidence.b, active: answer.strips.a,
                          words: answer.strips.wordsA, paint: store.paintA, frames: framesA)
                    spool(recordB, side: answer.evidence.b, other: answer.evidence.a, active: answer.strips.b,
                          words: answer.strips.wordsB, paint: store.paintB, frames: framesB)
                }
                SoundStripLegend()
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the fingerprints and the catalog…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .task { store.load(model: model, a: recordA, b: recordB) }
        // One structured task per card: leaving the view cancels the
        // decode (and its ffmpeg children). Keyed on the path so a reused
        // view never shows the previous pair's frames.
        .task(id: recordA.fullPath) {
            await framesA.load(CompareFilmstripRequest(record: recordA), cache: model.thumbnailCache)
        }
        .task(id: recordB.fullPath) {
            await framesB.load(CompareFilmstripRequest(record: recordB), cache: model.thumbnailCache)
        }
        .accessibilityIdentifier("compareMedia")
    }

    // MARK: The band, the lines, the recommendation

    private func verdictCard(_ answer: RelatedAnswer) -> some View {
        let band = answer.verdict.band
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(band.word.uppercased())
                    .font(.system(size: 13, weight: .heavy)).tracking(0.6)
                Text(CompareMediaWords.duration(band, answer.evidence))
                    .font(.system(size: 12, design: .monospaced))
                Spacer()
            }
            .foregroundStyle(Self.bandForeground(band))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Self.bandColor(band))
            VStack(alignment: .leading, spacing: 8) {
                Text(answer.verdict.headline).font(.system(size: 15, weight: .semibold))
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(answer.verdict.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(Self.lineColor(line.kind)).frame(width: 8, height: 8)
                            Text(line.words).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(answer.recommendation.words).font(.system(size: 13, weight: .medium))
                    if !answer.recommendation.why.isEmpty {
                        Text(answer.recommendation.why).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Self.bandColor(band).opacity(0.5)))
        .accessibilityIdentifier("compareMedia.verdict")
    }

    // MARK: One spool: the facts, then the frames over the sound

    private func spool(_ r: VideoRecord, side: RelatedEvidence.Side, other: RelatedEvidence.Side,
                       active: [Bool]?, words: String?, paint: SoundStripPaint?,
                       frames: CompareFilmstripLoader) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(r.filename).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(r.volumeName.isEmpty ? r.directory : r.volumeName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                ForEach(CompareMediaWords.facts(r, side: side, other: other), id: \.name) { fact in
                    GridRow {
                        Text(fact.name).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(fact.value).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(fact.differs ? Color.orange : Color.primary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            // Same width as the strip below: frame i sits over the i-th
            // eighth of the seconds.
            CompareFilmstripView(loader: frames) { MediaOpener.open([r]) }
            soundRows(active: active, words: words, paint: paint, durationSeconds: side.durationSeconds)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func soundRows(active: [Bool]?, words: String?, paint: SoundStripPaint?, durationSeconds: Double) -> some View {
        // nil = not measured: say so — an empty strip would draw silence.
        if let active {
            SoundStrip(active: active, matched: paint?.matched, durationSeconds: durationSeconds)
                .frame(height: 44)
            if paint?.fingerprintStale == true {
                Text(SoundStripPaint.staleWords).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            // A quiet strip from the stamp says why it is quiet.
            if let words { Text(words).font(.system(size: 11)).foregroundStyle(.secondary) }
        } else {
            Text("Sound not measured").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(height: 44, alignment: .leading)
        }
    }

    static func bandColor(_ band: RelatedBand) -> Color {
        switch band {
        case .sameEvent: return Color(red: 0.18, green: 0.49, blue: 0.35)
        case .clipFromSameEvent: return Color(red: 0.50, green: 0.72, blue: 0.60)
        case .differentCapture: return Color(red: 0.79, green: 0.64, blue: 0.15)
        case .differentEvents: return Color(red: 0.64, green: 0.23, blue: 0.17)
        case .notEnoughEvidence: return Color.gray
        }
    }
    static func bandForeground(_ band: RelatedBand) -> Color {
        switch band {
        case .clipFromSameEvent, .differentCapture: return Color.black.opacity(0.85)
        default: return .white
        }
    }
    static func lineColor(_ kind: RelatedLine.Kind) -> Color {
        switch kind {
        case .supports: return .green
        case .contradicts: return .red
        case .differs: return .orange
        case .nonClue: return .gray
        case .missing: return .gray.opacity(0.5)
        }
    }
}

/// The sound as a strip: one bar per second (binned to the width), green
/// where the match covers it, the accent elsewhere, grey for silence.
/// Horizontal for now; the film spools turn it vertical.
struct SoundStrip: View {
    let active: [Bool]
    let matched: Range<Int>?
    let durationSeconds: Double
    /// Prefix sums over the audible seconds, built once per view value so
    /// every draw is O(width), not O(seconds) (codex 10/15 F6).
    private let bins: SoundStripBins

    init(active: [Bool], matched: Range<Int>?, durationSeconds: Double) {
        self.active = active
        self.matched = matched
        self.durationSeconds = durationSeconds
        self.bins = SoundStripBins(active: active, matched: matched, durationSeconds: durationSeconds)
    }

    var body: some View {
        Canvas { ctx, size in
            let n = bins.seconds
            let width = max(1, Int(size.width))
            let per = Double(n) / Double(width)
            for px in 0..<width {
                let s0 = Int(Double(px) * per), s1 = max(s0 + 1, Int(Double(px + 1) * per))
                let audible = bins.anyAudible(s0, min(s1, n)), inMatch = bins.anyMatched(s0, min(s1, n))
                let h = audible ? size.height * 0.85 : size.height * 0.18
                let rect = CGRect(x: CGFloat(px), y: size.height - h, width: 1, height: h)
                let color: Color = !audible ? SoundStripLegend.silence : inMatch ? SoundStripLegend.same : SoundStripLegend.unmatched
                ctx.fill(Path(rect), with: .color(color))
            }
        }
        .accessibilityLabel("sound strip")
    }
}

/// One caption line under the two strips: what the three colours mean.
struct SoundStripLegend: View {
    static let same = Color.green
    static let unmatched = Color.orange.opacity(0.8)
    static let silence = Color.gray.opacity(0.35)

    var body: some View {
        HStack(spacing: 4) {
            swatch(Self.same); Text("green = same sound in both")
            Text("·")
            swatch(Self.unmatched); Text("orange = sound not found in the other file")
            Text("·")
            swatch(Self.silence); Text("grey = silence")
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityIdentifier("compareMedia.legend")
    }

    private func swatch(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 8, height: 8)
    }
}

/// The strip's per-second facts, answered per pixel in O(1): prefix sums
/// over the audible seconds and the matched range. Pure.
struct SoundStripBins: Equatable {
    let seconds: Int
    private let audiblePrefix: [Int]
    private let matched: Range<Int>?

    init(active: [Bool], matched: Range<Int>?, durationSeconds: Double) {
        // A non-finite or negative duration falls back to the map (round 2 F3).
        let fromDuration = durationSeconds.isFinite ? Int(max(0, durationSeconds).rounded(.up)) : 0
        seconds = max(active.count, fromDuration, 1)
        var prefix = [Int](repeating: 0, count: active.count + 1)
        for (i, on) in active.enumerated() { prefix[i + 1] = prefix[i] + (on ? 1 : 0) }
        audiblePrefix = prefix
        self.matched = matched
    }

    /// Any audible second in `s0..<s1`?
    func anyAudible(_ s0: Int, _ s1: Int) -> Bool {
        let lo = max(0, min(s0, audiblePrefix.count - 1)), hi = max(0, min(s1, audiblePrefix.count - 1))
        return hi > lo && audiblePrefix[hi] - audiblePrefix[lo] > 0
    }

    /// Any matched second in `s0..<s1`?
    func anyMatched(_ s0: Int, _ s1: Int) -> Bool {
        guard let m = matched, s1 > s0 else { return false }
        return s0 < m.upperBound && s1 > m.lowerBound
    }

    /// Any audible second the matched range leaves out (all of them when
    /// nothing matched) — the seconds the strip would paint orange.
    var hasAudibleOutsideMatch: Bool {
        guard let m = matched else { return anyAudible(0, seconds) }
        return anyAudible(0, m.lowerBound) || anyAudible(m.upperBound, seconds)
    }
}

/// What one side's strip paints (Rick 2026-10-22). Two byte-identical files
/// have the same sound by definition, so the strip paints every audible
/// second green — never orange as if the sound differed — and flags the
/// fingerprint as stale when its stored match left audible seconds out.
/// Any other pair paints the stored match as is. Pure.
struct SoundStripPaint: Equatable {
    /// The range drawn green.
    let matched: Range<Int>?
    /// Byte-identical, yet the stored match missed audible seconds.
    let fingerprintStale: Bool

    static let staleWords = "fingerprint stale; sound is identical (same bytes)"

    init(active: [Bool], matched: Range<Int>?, durationSeconds: Double, identicalBytes: Bool) {
        guard identicalBytes else {
            self.matched = matched
            fingerprintStale = false
            return
        }
        let bins = SoundStripBins(active: active, matched: matched, durationSeconds: durationSeconds)
        self.matched = 0..<bins.seconds
        fingerprintStale = bins.hasAudibleOutsideMatch
    }
}

/// Words for the band's duration and the fact rows — pure, so tests pin them.
enum CompareMediaWords {
    struct Fact: Equatable {
        let name: String
        let value: String
        let differs: Bool
    }

    /// "37:30 of 38:00 · at 0:12" / "1:18 of 38:00 · at 6:16" / "19 s shared" / "byte for byte".
    static func duration(_ band: RelatedBand, _ e: RelatedEvidence) -> String {
        let m = RelatedLadder.mmss
        switch band {
        case .sameEvent:
            let identical = e.a.digest != nil && e.a.digest == e.b.digest && e.a.sizeBytes == e.b.sizeBytes && e.a.sizeBytes > 0
            return identical ? "byte for byte · \(m(e.a.durationSeconds))"
                : "\(m(min(e.a.durationSeconds, e.b.durationSeconds))) of \(m(max(e.a.durationSeconds, e.b.durationSeconds)))"
        case .clipFromSameEvent(let clip, let seconds, let offset):
            let master = clip == .a ? e.b : e.a
            return "\(m(seconds)) of \(m(master.durationSeconds)) · at \(m(offset))"
        case .differentCapture(let shared):
            return shared > 0 ? "\(Int(shared.rounded())) s of shared sound" : "no shared sound"
        case .differentEvents: return "no shared minute"
        case .notEnoughEvidence: return ""
        }
    }

    /// The card's `length`: the catalog table's own formatter (HH:MM:SS,
    /// whole seconds truncated), so the card and the table say the same
    /// thing for the same file (Rick 10/22: 19:36 here vs 00:19:35 there).
    static func length(_ seconds: Double) -> String {
        Formatting.duration(seconds.isFinite ? max(0, seconds) : 0)
    }

    static func facts(_ r: VideoRecord, side: RelatedEvidence.Side, other: RelatedEvidence.Side) -> [Fact] {
        let m = RelatedLadder.mmss
        func fact(_ name: String, _ value: String, _ otherValue: String) -> Fact { Fact(name: name, value: value, differs: value != otherValue) }
        let sha = side.digest.map { "\($0.prefix(4))…\($0.suffix(4))" } ?? "not hashed"
        let otherSha = other.digest.map { "\($0.prefix(4))…\($0.suffix(4))" } ?? "not hashed"
        let date = side.day.map { d in "\(d.year)-\(String(format: "%02d-%02d", d.month, d.day))\(side.dayIsReliable ? "" : " (file date)")" } ?? "no date"
        let otherDate = other.day.map { d in "\(d.year)-\(String(format: "%02d-%02d", d.month, d.day))\(other.dayIsReliable ? "" : " (file date)")" } ?? "no date"
        let sound = side.audibleSeconds.map { $0 <= 0 ? "no sound" : "\(m($0)) audible" } ?? "no fingerprint"
        let otherSound = other.audibleSeconds.map { $0 <= 0 ? "no sound" : "\(m($0)) audible" } ?? "no fingerprint"
        let codecs = [r.videoCodec, r.audioCodec].filter { !$0.isEmpty }.joined(separator: " · ")
        return [
            fact("length", length(side.durationSeconds), length(other.durationSeconds)),
            Fact(name: "codecs", value: codecs.isEmpty ? "—" : codecs, differs: side.codec != other.codec),
            Fact(name: "frame", value: r.resolution.isEmpty ? "—" : r.resolution, differs: side.frameHeight != other.frameHeight),
            fact("size", CatalogStorageTotals.displaySize(side.sizeBytes), CatalogStorageTotals.displaySize(other.sizeBytes)),
            fact("SHA-256", sha, otherSha),
            fact("date", date, otherDate),
            fact("sound", sound, otherSound),
            Fact(name: "people", value: side.people.isEmpty ? "—" : side.people.sorted().joined(separator: ", "), differs: side.people != other.people),
            fact("archive", side.isArchiveFile ? "archive file" : side.isArchived ? "content archived" : "not archived",
                 other.isArchiveFile ? "archive file" : other.isArchived ? "content archived" : "not archived"),
        ]
    }
}
