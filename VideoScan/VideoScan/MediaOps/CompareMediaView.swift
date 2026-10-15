// CompareMediaView.swift
// Compare Media, step 1 of the view (docs/design/event_analyzer_compare_media_2026_10_15.md §2):
// the verdict band, the evidence lines, the recommendation, and the two
// sound spools — drawn from last night's fingerprints — above the
// existing pair-compare detail (streams table, tiers). The film frames
// and the next-face buttons come next (§3).
//
//   ┌ SAME EVENT · 37:30 of 38:00 · at 0:12 ──────────────────────┐  the band
//   │ Two transfers of one recording.                              │
//   │ ● Sound: 99 % … ● Same day … ○ Different bytes …             │  the lines
//   │ Master is archived in the better transfer. Remove …  [door]  │
//   └──────────────────────────────────────────────────────────────┘
//   ┌ name A ─────────┐   ┌ name B ─────────┐
//   │ facts, diffs in │   │ facts …         │
//   │ the accent      │   │                 │
//   │ ▌sound strip    │   │ ▌sound strip    │  time runs down; green = matched
//   └─────────────────┘   └─────────────────┘
//
// PERF: the answer is computed once per pair in the store's task (the
// projection on the main actor, the match off it) and cached; the view
// reads values. Nothing in a body touches the catalog or the disk.

import Combine
import SwiftUI
import VideoScanCore

@MainActor
final class CompareMediaStore: ObservableObject {
    @Published private(set) var answer: RelatedAnswer?
    @Published private(set) var isWorking = false
    private var task: Task<Void, Never>?

    func load(model: VideoScanModel, a: VideoRecord, b: VideoRecord) {
        guard task == nil else { return }
        isWorking = true
        task = Task { [weak self] in
            let answer = await model.relatedAnswer(a: a, b: b)
            guard let self, !Task.isCancelled else { return }
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
    /// never in this body); the body reads only the store's cached answer.
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject private var model: VideoScanModel
    @StateObject private var store = CompareMediaStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let answer = store.answer {
                verdictCard(answer)
                HStack(alignment: .top, spacing: 12) {
                    spool(recordA, side: answer.evidence.a, other: answer.evidence.b, active: answer.strips.a, matched: answer.strips.matchedA)
                    spool(recordB, side: answer.evidence.b, other: answer.evidence.a, active: answer.strips.b, matched: answer.strips.matchedB)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the fingerprints and the catalog…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .task { store.load(model: model, a: recordA, b: recordB) }
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

    // MARK: One spool: the facts, then the sound

    private func spool(_ r: VideoRecord, side: RelatedEvidence.Side, other: RelatedEvidence.Side,
                       active: [Bool], matched: Range<Int>?) -> some View {
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
            SoundStrip(active: active, matched: matched, durationSeconds: side.durationSeconds)
                .frame(height: 44)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
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

    var body: some View {
        Canvas { ctx, size in
            let n = max(active.count, Int(durationSeconds.rounded(.up)), 1)
            let bins = max(1, Int(size.width))
            let per = Double(n) / Double(bins)
            for px in 0..<bins {
                let s0 = Int(Double(px) * per), s1 = max(s0 + 1, Int(Double(px + 1) * per))
                var audible = false, inMatch = false
                for s in s0..<min(s1, n) {
                    if s < active.count, active[s] { audible = true }
                    if let m = matched, m.contains(s) { inMatch = true }
                }
                let h = audible ? size.height * 0.85 : size.height * 0.18
                let rect = CGRect(x: CGFloat(px), y: size.height - h, width: 1, height: h)
                let color: Color = !audible ? Color.gray.opacity(0.35) : inMatch ? Color.green : Color.orange.opacity(0.8)
                ctx.fill(Path(rect), with: .color(color))
            }
        }
        .accessibilityLabel("sound strip")
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
            return e.a.digest != nil && e.a.digest == e.b.digest ? "byte for byte · \(m(e.a.durationSeconds))"
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
            fact("length", m(side.durationSeconds), m(other.durationSeconds)),
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
