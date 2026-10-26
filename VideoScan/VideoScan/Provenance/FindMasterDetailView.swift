// FindMasterDetailView.swift — the Find Master row's detail in the Media
// File Operations window: per selected file, the ranked answers (each one
// sentence carrying its evidence) and Reveal in Catalog; refusals and
// negatives in words. Reads only the job's published values — no
// O(records) work in the body (rule 5); the wording is FindMasterAnswer's.

import SwiftUI
import VideoScanCore

struct FindMasterDetailView: View {
    @ObservedObject var job: FindMasterJob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let report = job.buildReport {
                Text("Sound index: \(report.indexed.formatted()) contents, \(report.landmarks.formatted()) landmarks. Proof is sound only; which copy is the better or original transfer is your decision.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(job.results) { result in
                        section(result)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor).opacity(0.5)))
        .accessibilityIdentifier("mfo.findMaster.detail")
    }

    @ViewBuilder private func section(_ result: FindMasterResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            switch result.outcome {
            case .refused(let reason):
                line(icon: "nosign", tint: .orange, text: FindMasterAnswer.refusal(reason))
            case .noneFound(let searched, let unreadable):
                line(icon: unreadable.isEmpty ? "magnifyingglass" : "exclamationmark.triangle",
                     tint: unreadable.isEmpty ? .secondary : .orange, text: FindMasterAnswer.noneFound(
                    searched: searched, noSoundTrack: job.plan.noSoundTrackContents,
                    notFingerprinted: job.plan.notFingerprintedContents, unreadable: unreadable.count))
                unreadableRows(unreadable)
            case .found(let found, _, let unreadable):
                let halves = FindMasterAnswer.split(found)
                // One line per group of copies matching at the same spot
                // (a "recording"); a few dozen hits at most, not O(records).
                let groups = FindMasterAnswer.groups(halves.strong, name: job.otherName)
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    FindMasterGroupRow(job: job, group: group)
                }
                if !halves.weak.isEmpty {
                    FindMasterWeakGroup(job: job, weak: halves.weak)
                }
                unreadableRows(unreadable)
            }
        }
    }

    /// Candidates the index chose whose print could not be read: verdict
    /// unknown, named with the reason.
    @ViewBuilder private func unreadableRows(_ unreadable: [AudioMasterUnreadable]) -> some View {
        ForEach(Array(unreadable.enumerated()), id: \.offset) { _, u in
            line(icon: "exclamationmark.triangle", tint: .orange,
                 text: "Could not be read: \(FindMasterAnswer.name(of: u.key, label: job.plan.labels[u.key.contentDigest])) — \(u.reason)")
        }
    }

    private func line(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint).font(.system(size: 11)).frame(width: 14)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Weak overlaps: counted in the header, COLLAPSED by default (shown on
/// demand, never hidden).
struct FindMasterWeakGroup: View {
    @ObservedObject var job: FindMasterJob
    let weak: [AudioMasterCandidate]
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(Array(weak.enumerated()), id: \.offset) { _, candidate in
                FindMasterFoundRow(job: job, candidate: candidate)
            }
        } label: {
            Text(FindMasterAnswer.weakHeader(count: weak.count))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("mfo.findMaster.weakOverlaps")
    }
}

/// One group of copies at the same spot: verdict chip, the first file's
/// name, its span, Reveal — and "+ N copies at the same spot: a, b" under
/// it. The full evidence sentence for each member is the tooltip (and is in
/// the log, one line per hit).
struct FindMasterGroupRow: View {
    @ObservedObject var job: FindMasterJob
    let group: FindMasterAnswer.HitGroup

    var body: some View {
        let first = group.members[0]
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.chip)
                    .font(.system(size: 10, weight: .semibold)).textCase(.uppercase)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
                Text(job.otherName(first)).font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(FindMasterAnswer.shortSpan(group.start, group.end))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let label = job.plan.labels[first.key.contentDigest] {
                    Button {
                        job.reveal(label.recordID)
                    } label: {
                        Label("Reveal in Catalog", systemImage: "film.stack").font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(label.path)
                }
            }
            if let copies = FindMasterAnswer.copiesLine(group.members.dropFirst().map(job.otherName)) {
                Text(copies).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
            }
        }
        .help(group.members.map(job.answer).joined(separator: "\n"))
        .accessibilityIdentifier("mfo.findMaster.group")
    }
}

/// One found content: verdict chip, the sentence, Reveal in Catalog
/// (the weak-overlap list, collapsed by default).
struct FindMasterFoundRow: View {
    @ObservedObject var job: FindMasterJob
    let candidate: AudioMasterCandidate

    var body: some View {
        let c = candidate
        HStack(alignment: .top, spacing: 8) {
            Text(FindMasterAnswer.chip(c.match.verdict))
                .font(.system(size: 10, weight: .semibold)).textCase(.uppercase)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.2)))
            Text(job.answer(c)).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let label = job.plan.labels[c.key.contentDigest] {
                Button {
                    job.reveal(label.recordID)
                } label: {
                    Label("Reveal in Catalog", systemImage: "film.stack").font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(label.path)
            }
        }
    }
}
