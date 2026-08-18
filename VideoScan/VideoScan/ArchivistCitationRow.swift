//
//  ArchivistCitationRow.swift
//  VideoScan
//
//  One cited video in Hallie's answer. Rick 2026-08-17 (picky items, gladly):
//    • actions as colored, spaced, iconed buttons — Play blue, Reveal in
//      Finder green, Show in Catalog purple;
//    • the path and the "confirmed blah blah" basis lines are folded behind
//      a chevron ("Details") that rolls out Path / Year / Duration / People
//      / Why it matched — a list we can grow or trim as this evolves.
//

import SwiftUI

struct ArchivistCitationRow: View {
    let index: Int
    let citation: HallieTurnExecutor.Citation
    let timestampSuffix: String
    let basisLines: [String]
    let record: VideoRecord?
    let onPlay: () -> Void
    let onReveal: () -> Void
    let onShowInCatalog: () -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide details" : "Details — path, year, people, why it matched")
                Text("\(index + 1). \(citation.filename)\(timestampSuffix)")
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
            }
            HStack(spacing: 14) {
                actionButton("Play", systemImage: "play.fill", color: .blue, action: onPlay)
                actionButton("Reveal in Finder", systemImage: "folder", color: .green, action: onReveal)
                actionButton("Show in Catalog", systemImage: "film.stack", color: .purple, action: onShowInCatalog)
            }
            .padding(.leading, 20)
            if expanded {
                details
                    .padding(.leading, 20)
                    .transition(.opacity)
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String, color: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    /// The details grid. Rows come from the record when we have it; the
    /// list is meant to be edited freely as the archivist grows.
    private var details: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
            detailRow("Path", citation.fullPath, monospaced: true)
            if let rec = record {
                if let year = Self.year(of: rec) { detailRow("Year", year) }
                if rec.durationSeconds > 0 { detailRow("Duration", Self.duration(rec.durationSeconds)) }
                let people = Self.people(of: rec)
                if !people.isEmpty { detailRow("People", people) }
                if !rec.videoCodec.isEmpty || !rec.container.isEmpty {
                    detailRow("Format", [rec.container, rec.videoCodec].filter { !$0.isEmpty }.joined(separator: " · "))
                }
                let vol = VolumeReachability.volumeName(forPath: rec.fullPath)
                if !vol.isEmpty { detailRow("Volume", vol) }
            }
            if !basisLines.isEmpty { detailRow("Why it matched", basisLines.joined(separator: "; ")) }
        }
        .font(.system(size: 13))
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label + ":").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }

    // MARK: helpers (pure)

    static func year(of rec: VideoRecord) -> String? {
        if let d = rec.inferredRecordDate ?? rec.embeddedCreationDate {
            return String(Calendar.current.component(.year, from: d))
        }
        if let ud = rec.userDate, !ud.isEmpty { return ud }
        return nil
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded()); let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func people(of rec: VideoRecord) -> String {
        var names: [String] = []
        names += rec.confirmedByUserPeople.map(\.name)
        names += rec.detectedPeople.filter { !names.contains($0) }
        names += rec.suspectedPeople.filter { !names.contains($0) }.map { $0 + "?" }
        return names.joined(separator: ", ")
    }
}
