import SwiftUI

// MARK: - "Get Info…" ⌘I (Rick 2026-10-08; was "Get Media Info…", and
// before that "Audio Info…")
//
// The facts sheet: container, every stream, and the last Verify
// verdict. Presentation only — it writes nothing. One header probe in
// `.task` (sub-second, off the main actor via the @concurrent probe);
// offline files show what the catalog already knows instead.
//
// Shares the MediaFacts model with Check Media and the card view with the
// Check Media job's detail — one model, two views.
//
// Presented with `.sheet(item:)`. Its two buttons hand off to other
// sheets AFTER this one starts dismissing (VerifyAudioDismissHandoff) —
// never a sheet chained on a sheet.

struct MediaInfoRequest: Identifiable {
    let id = UUID()
    let record: VideoRecord
    /// This session's Verify Audio / Check Media sound diagnosis, if any —
    /// carries the per-channel levels and the Balance / Rebuild offers.
    let audioDiagnosis: AudioVerifyDiagnosis?
    let onCheckMedia: () -> Void
    /// Opens the Repair sheet (the plan) — Get Info's banner button.
    var onRepair: (() -> Void)?
    let onSoundDetails: (() -> Void)?
}

struct MediaInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: MediaInfoRequest

    private enum Load {
        case loading
        case loaded(MediaFacts)
        case unavailable(String)
    }
    @State private var load: Load = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Media Information")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("mediaInfo.title")
            Text(request.record.filename)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

            verdictBox
            repairBanner
            repairedCopyLine

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    factsBody
                    if let card = request.record.mediaReportCard {
                        DisclosureGroup("Report card") {
                            MediaReportCardView(card: card).padding(.top, 6)
                        }
                        .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 260, maxHeight: 460)

            buttons
        }
        .padding(24)
        .frame(width: 640)
        .task { await loadFacts() }
    }

    // MARK: Verdict line

    @ViewBuilder
    private var verdictBox: some View {
        if let card = request.record.mediaReportCard {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.displayHeadline).font(.body.weight(.medium))
                    Text("Last checked \(card.checkedAt.formatted(date: .abbreviated, time: .shortened))\(card.isCurrent(forSizeBytes: request.record.sizeBytes) ? "" : " — the file has changed since")")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } icon: {
                MediaVerdictIcon(verdict: card.verdict, quickPassOnly: card.isQuickPassOnly)
            }
            .accessibilityIdentifier("mediaInfo.verdict")
        } else {
            Label("Not verified yet — Verify… looks for broken timing, damage and sound problems.",
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// The ORANGE "Recommended action" box with the GREEN button, when the
    /// current card has something Repair can fix (Rick 2026-10-08). The
    /// button opens the Repair sheet, which shows the plan before running.
    @ViewBuilder
    private var repairBanner: some View {
        let r = request.record
        if let card = r.mediaReportCard, card.isCurrent(forSizeBytes: r.sizeBytes), let onRepair = request.onRepair {
            let offers = MediaRepairPlan.offers(for: card, sound: MediaRepairSoundFacts(diagnosis: request.audioDiagnosis),
                                                originalProtected: false)
            MediaRepairBanner(advice: MediaRepairAdvice.advice(for: card, offers: offers,
                                                              balance: MediaRepairBalanceInput(diagnosis: request.audioDiagnosis),
                                                              sourceName: r.filename),
                              buttonTitle: "Repair Now\u{2026}", action: { handOff(onRepair) })
        }
    }

    /// "Repaired copy: …" — the link Repair left on this file's card.
    @ViewBuilder
    private var repairedCopyLine: some View {
        if let link = request.record.mediaReportCard?.repairedCopy {
            Label("Repaired copy: \((link.path as NSString).lastPathComponent) (\(link.repairedAt.formatted(date: .abbreviated, time: .shortened)))",
                  systemImage: "checkmark.seal")
                .font(.callout)
                .foregroundStyle(.green)
                .help(link.path)
                .accessibilityIdentifier("mediaInfo.repairedCopy")
        }
    }

    private var buttons: some View {
        HStack {
            Button(CatalogRowMenuText.verify(count: 1)) { handOff(request.onCheckMedia) }
                .accessibilityIdentifier("mediaInfo.checkMedia")
            if let sound = request.onSoundDetails {
                Button("Sound Details\u{2026}") { handOff(sound) }
                    .accessibilityIdentifier("mediaInfo.soundDetails")
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.escape)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
    }

    private func handOff(_ action: @escaping () -> Void) {
        VerifyAudioDismissHandoff.perform(dismiss: { dismiss() }, action: action)
    }

    // MARK: Facts

    @ViewBuilder
    private var factsBody: some View {
        switch load {
        case .loading:
            ProgressView("Reading the file's header…").controlSize(.small)
        case .unavailable(let why):
            Text(why).font(.callout).foregroundStyle(.secondary)
            catalogFacts
        case .loaded(let facts):
            MediaFactsView(facts: facts, channelLevels: channelLevels)
        }
    }

    /// What the catalog scan recorded — for offline files.
    private var catalogFacts: some View {
        let r = request.record
        return MediaFactsSection(title: "From the catalog", rows: [
            ("Duration", r.duration), ("Video codec", r.videoCodec), ("Resolution", r.resolution),
            ("Frame rate", r.frameRate), ("Audio codec", r.audioCodec), ("Channels", r.audioChannels),
            ("Sample rate", r.audioSampleRate), ("Bit depth", r.bitDepth),
        ])
    }

    /// Per-channel loudness: this session's diagnosis, else the card's
    /// persisted sound row.
    private var channelLevels: [MediaEvidence] {
        if let channels = request.audioDiagnosis?.balanceAnalysis?.measurements.channels, !channels.isEmpty {
            return channels.enumerated().map { i, c in
                MediaEvidence(CheckMediaRules.channelName(i, of: channels.count), CheckMediaRules.levelText(c))
            }
        }
        return request.record.mediaReportCard?.check(.sound)?.evidence ?? []
    }

    private func loadFacts() async {
        let path = request.record.fullPath
        guard VolumeReachability.isReachable(path: path) else {
            load = .unavailable("The file's drive isn't connected — showing what the catalog recorded.")
            return
        }
        switch await CheckMediaProbe.facts(path: path) {
        case .success(let f): load = .loaded(f)
        case .failure(let e): load = .unavailable("Couldn't read the file (\(e.reason)) — showing what the catalog recorded.")
        }
    }
}

/// The facts, one section per container / stream.
struct MediaFactsView: View {
    let facts: MediaFacts
    var channelLevels: [MediaEvidence] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MediaFactsSection(title: "File", rows: MediaFactsRows.container(facts))
            ForEach(facts.streams) { s in
                MediaFactsSection(title: MediaFactsRows.title(s),
                                  rows: MediaFactsRows.stream(s) + (s.id == facts.audio?.id ? levelRows : []))
            }
        }
    }

    private var levelRows: [(String, String)] {
        channelLevels.map { ("Loudness — \($0.label)", $0.value) }
    }
}

struct MediaFactsSection: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.filter { !$0.1.isEmpty }.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.0).foregroundStyle(.secondary).frame(width: 190, alignment: .leading)
                        Text(row.1).font(.callout.monospaced()).textSelection(.enabled)
                    }
                    .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

/// The facts as labelled rows — pure, so the wording is testable. Empty
/// values are dropped by the section.
enum MediaFactsRows {
    typealias V = VerifyVideoRules

    static func container(_ f: MediaFacts) -> [(String, String)] {
        [("Container", f.formatLongName.isEmpty ? f.formatName : "\(f.formatLongName) (\(f.formatName))"),
         ("Duration", f.durationSeconds.map { "\(V.durationText($0)) (\(String(format: "%.3f", $0)) s)" } ?? ""),
         ("Size", f.sizeBytes.map { "\(V.sizeText($0)) (\(V.groupedInt(Int($0))) bytes)" } ?? ""),
         ("Implied bitrate", f.impliedBitRate.map(V.bitrateText) ?? ""),
         ("Encoder", f.encoder),
         ("Created", f.creationTime),
         ("Start time", f.startTimeSeconds.map { String(format: "%.3f s", $0) } ?? "")]
    }

    static func title(_ s: MediaStreamFacts) -> String {
        let kind = s.isAttachedPicture ? "cover picture" : s.kind.rawValue
        return "Stream \(s.index) — \(kind)"
    }

    static func stream(_ s: MediaStreamFacts) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("Codec", [s.codec, s.profile.isEmpty ? "" : "(\(s.profile))"].filter { !$0.isEmpty }.joined(separator: " ")),
        ]
        switch s.kind {
        case .video: rows += picture(s)
        case .audio: rows += sound(s)
        default: break
        }
        rows += [("Duration", s.durationSeconds.map { String(format: "%.3f s", $0) } ?? ""),
                 ("Bitrate", s.bitRate.map(V.bitrateText) ?? ""),
                 ("Time base", s.timeBase),
                 ("Start time", s.startTimeSeconds.map { String(format: "%.3f s", $0) } ?? ""),
                 ("Created", s.creationTime)]
        return rows
    }

    private static func picture(_ s: MediaStreamFacts) -> [(String, String)] {
        let size = (s.width.flatMap { w in s.height.map { "\(w)×\($0)" } }) ?? ""
        return [("Resolution", size),
                ("Pixel shape (SAR)", s.sampleAspectRatio),
                ("Shown as (DAR)", s.displayAspectRatio),
                ("Pixel format", s.pixelFormat),
                ("Field order", s.fieldOrder),
                ("Frame rate (r_frame_rate)", rate(s.rFrameRateText, s.rFrameRate)),
                ("Frame rate (average)", rate(s.avgFrameRateText, s.avgFrameRate)),
                ("Frames", s.frameCount.map(V.groupedInt) ?? "")]
    }

    private static func sound(_ s: MediaStreamFacts) -> [(String, String)] {
        let channels = s.channels.map { n in s.channelLayout.isEmpty ? "\(n)" : "\(n) (\(s.channelLayout))" } ?? ""
        let depth = [s.bitDepth.map { "\($0)-bit" } ?? "", s.sampleFormat].filter { !$0.isEmpty }.joined(separator: ", ")
        return [("Sample rate", s.sampleRate.map { "\($0) Hz" } ?? ""),
                ("Channels", channels),
                ("Bit depth / format", depth),
                ("Samples", s.sampleCount.map { V.groupedInt(Int($0)) } ?? "")]
    }

    /// "90000/1 (90,000 fps)".
    static func rate(_ text: String, _ value: Double) -> String {
        guard !text.isEmpty, text != "0/0" else { return "" }
        return "\(text) (\(V.fpsText(value)) fps)"
    }
}
