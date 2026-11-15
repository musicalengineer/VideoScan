import SwiftUI

// MARK: - FileJourneySheet
//
// One sheet for one piece of footage (Rick 2026-11-14), most important first:
//
//   1. the ladder      where it stands — Catalogued · Analyzed · Reviewed ·
//                      Archived, green ticks, always in view (it does not scroll)
//   2. the timeline    how it got there — one dated line per real event
//   3. the details     the file's own facts, its status, notes, other copies
//
// Archive Details and the File Journey were two sheets with two ladders; both
// menu items now open this one.
//
// The sheet is a pure function of one `FileJourney` value, built once when it
// opens (FileJourneyBuilder): the view computes nothing over records, and the
// ladder and the timeline cannot describe different states of the same file.
//
// Type sizes are deliberate: Rick reads this at a glance and does not want to
// squint. The DATE of each event is the heaviest thing on its line, in the
// event's own colour.

struct FileJourneySheet: View {
    @Environment(\.dismiss) private var dismiss
    let journey: FileJourney

    @State private var showCopies: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !journey.preservation.isEmpty {
                    PreservationChecklistStrip(steps: journey.preservation)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    timeline
                    if !journey.otherKnownCopies.isEmpty {
                        copiesDisclosure
                    }
                    ForEach(journey.details) { section in
                        detailSection(section)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            buttonBar
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
        // Large by default (Rick: "big enough so we can see at a glance"):
        // the ladder and a full timeline fit without scrolling.
        .frame(minWidth: 720, idealWidth: 840, minHeight: 640, idealHeight: 900)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: journey.isMarkedDeleted ? "archivebox" : "film.stack")
                .font(.system(size: 36))
                .foregroundColor(journey.isMarkedDeleted ? .brown : .blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(journey.filename)
                    .font(.title2.bold())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("fileJourney.title")
                Text("Where this footage stands, and how it got here.")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Timeline

    @ViewBuilder
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Journey")
                .padding(.bottom, 8)
            ForEach(Array(journey.events.enumerated()), id: \.element.id) { idx, evt in
                timelineRow(event: evt,
                            isFirst: idx == 0,
                            isLast: idx == journey.events.count - 1)
            }
        }
    }

    @ViewBuilder
    private func timelineRow(event: JourneyEvent, isFirst: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Spine with the icon at the top; the line runs on to the next event.
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : Color.secondary.opacity(0.3))
                    .frame(width: 2, height: 6)
                ZStack {
                    Circle()
                        .fill(event.color.opacity(0.18))
                        .frame(width: 34, height: 34)
                    Image(systemName: event.icon)
                        .foregroundColor(event.color)
                        .font(.system(size: 16, weight: .semibold))
                }
                Rectangle()
                    .fill(isLast ? Color.clear : Color.secondary.opacity(0.3))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                if !event.displayStamp.isEmpty {
                    Text(event.displayStamp)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(event.kind.stampColor)
                }
                Text(event.sentence)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.top, 7)
            .padding(.bottom, 10)
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("fileJourney.event.\(event.kind.rawValue)")
    }

    // MARK: - Other copies disclosure

    @ViewBuilder
    private var copiesDisclosure: some View {
        DisclosureGroup(isExpanded: $showCopies) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(journey.otherKnownCopies) { copy in
                    copyRow(copy)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("\(journey.otherKnownCopies.count) other cop\(journey.otherKnownCopies.count == 1 ? "y" : "ies") known")
                .font(.system(size: 14, weight: .medium))
                .accessibilityIdentifier("fileJourney.copiesDisclosure")
        }
        .padding(10)
        .background(Color.green.opacity(0.05))
        .cornerRadius(8)
    }

    private func copyRow(_ copy: KnownCopy) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: copy.isSafe ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .foregroundColor(copy.isSafe ? .green : .orange)
                .font(.system(size: 13))
                .frame(width: 16)
            Text(copy.volumeName)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(copy.isSafe ? .primary : .secondary)
            Text("·")
                .foregroundColor(.secondary)
            Text(copy.role.rawValue)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text("·")
                .foregroundColor(.secondary)
            Text(copy.trust.rawValue)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            if !copy.isSafe {
                Text(copy.isRetired ? "(retired)" : "(unreliable)")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            }
            Spacer()
            Text((copy.path as NSString).lastPathComponent)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .opacity(copy.isSafe ? 1.0 : 0.7)
    }

    // MARK: - Detail sections

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .heavy))
            .kerning(0.8)
            .foregroundColor(.secondary)
    }

    @ViewBuilder
    private func detailSection(_ section: JourneyDetailSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(section.title)
            ForEach(section.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.label)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .frame(width: 130, alignment: .trailing)
                    Text(row.value)
                        .font(.system(size: 14, weight: .medium))
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
            if !section.text.isEmpty {
                Text(section.text)
                    .font(section.isMachineText ? .system(size: 12, design: .monospaced) : .system(size: 14))
                    .foregroundColor(section.isMachineText ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("fileJourney.details.\(section.title)")
    }

    // MARK: - Buttons

    private var buttonBar: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("fileJourney.done")
        }
    }
}
