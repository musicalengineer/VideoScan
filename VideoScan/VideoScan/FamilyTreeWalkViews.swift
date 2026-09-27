// FamilyTreeWalkViews.swift
// Small read-only views of the Family Tree Walk (Rick 2026-09-27):
//   • TreeWalkSummaryView — counts by line, by birth region, checks by
//     kind, coverage. Shown at the end of the foreground animation and in
//     the MFO row's detail.
//   • WalkTreeJobDetailView — the MFO row's expanded detail.
//   • FamilyTreeWalkDecorationPanel — the inspector's block for the
//     selected person (line, generations, age at death, region, counts,
//     checks). One dictionary lookup per body evaluation; no O(people)
//     work in any body.
//
// Colours by line — the same everywhere (inspector, animation, summary):
// first start (Rick) blue, second (Donna) rose, both violet, none grey,
// a check amber.

import SwiftUI
import VideoScanCore

enum TreeWalkPalette {
    static func color(_ line: TreeWalk.Line) -> Color {
        switch line {
        case .first: return Color(red: 0.25, green: 0.52, blue: 0.96)
        case .second: return Color(red: 0.93, green: 0.40, blue: 0.58)
        case .both: return Color(red: 0.62, green: 0.42, blue: 0.93)
        case .none: return Color(white: 0.55)
        }
    }
    static let check = Color(red: 1.0, green: 0.72, blue: 0.10)

    static func lineName(_ line: TreeWalk.Line, names: [String]) -> String {
        func name(_ i: Int) -> String { names.indices.contains(i) ? names[i] : (i == 0 ? "First" : "Second") }
        switch line {
        case .first: return "\(name(0))'s line"
        case .second: return "\(name(1))'s line"
        case .both: return "Both lines"
        case .none: return "Not on either line"
        }
    }
}

// MARK: - Summary

struct TreeWalkSummaryView: View {
    let summary: TreeWalk.Summary
    let displayNames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(summary.peopleWalked.formatted()) of \(summary.peopleInTree.formatted()) people walked · "
                 + "\(summary.generationsFromFirst) generations"
                 + (displayNames.count > 1 ? " / \(summary.generationsFromSecond)" : ""))
                .font(.system(size: 12, weight: .semibold))
            HStack(alignment: .top, spacing: 24) {
                section("By line") {
                    ForEach(TreeWalk.Line.allCases, id: \.self) { line in
                        if let n = summary.byLine[line], n > 0 {
                            row(TreeWalkPalette.lineName(line, names: displayNames), n, color: TreeWalkPalette.color(line))
                        }
                    }
                }
                section("Born in") {
                    ForEach(BirthplaceClassifier.BirthRegion.allCases, id: \.self) { region in
                        if let n = summary.byRegion[region], n > 0 { row(region.label, n) }
                    }
                }
                section("Checks (\(summary.warnCount.formatted()) warn, \(summary.infoCount.formatted()) info)") {
                    ForEach(TreeWalk.CheckKind.allCases, id: \.self) { kind in
                        if let n = summary.checksByKind[kind], n > 0 {
                            row(kind.label, n, color: kind.severity == .warn ? TreeWalkPalette.check : nil)
                        }
                    }
                }
            }
            section("Coverage (people walked)") {
                ForEach(summary.coverageWalked, id: \.field) { c in
                    Text(c.line + " (\(c.percent))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Text(String(format: "Walk %.1f ms · checks %.1f ms · total %.0f ms",
                        summary.walkMilliseconds, summary.checksMilliseconds, summary.totalMilliseconds))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .textSelection(.enabled)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ label: String, _ n: Int, color: Color? = nil) -> some View {
        HStack(spacing: 6) {
            if let color { Circle().fill(color).frame(width: 8, height: 8) }
            Text(label).font(.system(size: 11))
            Spacer(minLength: 8)
            Text(n.formatted()).font(.system(size: 11).monospacedDigit())
        }
        .frame(minWidth: 150)
    }
}

// MARK: - MFO row detail

struct WalkTreeJobDetailView: View {
    @ObservedObject var job: WalkTreeJob

    var body: some View {
        if let summary = job.summary {
            TreeWalkSummaryView(summary: summary, displayNames: job.displayNames)
        } else {
            Text(job.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Inspector

struct FamilyTreeWalkDecorationPanel: View {
    let personID: String
    @ObservedObject var center: FamilyTreeWalkCenter = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Tree Walk").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let d = center.decoration(for: personID) {
                decorated(d)
            } else if let status = center.status {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if center.stored != nil {
                Text("Not in the last walk (a hidden record, or added since).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("Reading the last walk…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ft.walkDecorations")
    }

    @ViewBuilder private func decorated(_ d: TreeWalk.Decoration) -> some View {
        let names = center.displayNames
        HStack(spacing: 6) {
            Circle().fill(TreeWalkPalette.color(d.line)).frame(width: 9, height: 9)
            Text(TreeWalkPalette.lineName(d.line, names: names)).font(.system(size: 12, weight: .medium))
            if d.inCycle {
                Text("in a loop").font(.system(size: 10, weight: .semibold)).foregroundStyle(TreeWalkPalette.check)
            }
        }
        ForEach(Array(generationLines(d, names: names).enumerated()), id: \.offset) { _, line in
            fact(line)
        }
        if let age = d.ageAtDeath { fact("Age at death \(age.spoken)") }
        fact("Born: \(d.birthRegion.label)" + (d.birthYear.map { " · \($0)" } ?? "")
             + (d.birthPrecision.map { $0 == .day || $0 == .month || $0 == .year ? "" : " (\($0.rawValue))" } ?? ""))
        fact("\(d.childCount) child\(d.childCount == 1 ? "" : "ren") recorded")
        fact("Ancestors \(d.ancestorCount.spoken)"
             + (d.documentedAncestorFraction.map { " · \(Int(($0 * 100).rounded()))% dated" } ?? "")
             + " · descendants \(d.descendantCount.spoken)")
        let checks = center.checks(for: personID)
        ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Circle().fill(check.severity == .warn ? TreeWalkPalette.check : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(check.reason).font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func generationLines(_ d: TreeWalk.Decoration, names: [String]) -> [String] {
        var out: [String] = []
        let pairs: [(Int?, Double?, Int)] = [(d.generationFromFirst, d.pathsFromFirst, 0),
                                             (d.generationFromSecond, d.pathsFromSecond, 1)]
        for (gen, paths, i) in pairs {
            guard let gen, gen > 0 else { continue }
            let who = names.indices.contains(i) ? names[i] : (i == 0 ? "first" : "second")
            var s = "\(who)'s \(d.relationLabel(generations: gen) ?? "ancestor") (\(gen) gen.)"
            if let paths {
                if paths.isNaN { s += " · above a loop" } else if paths > 1 {
                    s += " · \(paths < 1e15 ? Int(paths).formatted() : String(format: "%.1e", paths)) lines of descent"
                }
            }
            out.append(s)
        }
        return out
    }

    private func fact(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
