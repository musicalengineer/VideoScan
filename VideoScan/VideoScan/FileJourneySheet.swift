import SwiftUI

// MARK: - FileJourneySheet (View 2)
//
// "Following <filename>." Vertical timeline of every event we know about
// for a single VideoRecord: origin → reconcile/combine/relocate → current
// state, plus a disclosure listing other known copies.
//
// Friendly-tone copy per feedback_friendly_language.md — every sentence
// reads like a person describing what happened to a clip, not a forensic
// log.

struct FileJourneySheet: View {
    @Environment(\.dismiss) private var dismiss
    let journey: FileJourney

    @State private var showCopies: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            // The checklist sits ABOVE the timeline on purpose: history
            // is what happened, this is what is still missing, and the
            // second is the reason you opened the sheet.
            if !journey.preservation.isEmpty {
                PreservationChecklistStrip(steps: journey.preservation)
            }
            hashLine
            Divider()
            timeline
            if !journey.otherKnownCopies.isEmpty {
                copiesDisclosure
            }
            Spacer(minLength: 8)
            buttonBar
        }
        .padding(22)
        .frame(minWidth: 580, idealWidth: 640, minHeight: 520)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: journey.isMarkedDeleted
                              ? "archivebox"
                              : "film.stack")
                .font(.system(size: 32))
                .foregroundColor(journey.isMarkedDeleted ? .brown : .blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Following \(journey.filename)")
                    .font(.title2.bold())
                    .accessibilityIdentifier("fileJourney.title")
                Text("Here's everything I know about where this file has been.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var hashLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "number")
                .foregroundColor(.secondary)
                .font(.caption)
            Text(journey.hashStatusLine)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
        .accessibilityIdentifier("fileJourney.hashLine")
    }

    // MARK: - Timeline

    @ViewBuilder
    private var timeline: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(journey.events.enumerated()), id: \.element.id) { idx, evt in
                    timelineRow(event: evt,
                                isFirst: idx == 0,
                                isLast: idx == journey.events.count - 1)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(minHeight: 240)
    }

    @ViewBuilder
    private func timelineRow(event: JourneyEvent, isFirst: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Spine with icon at the midpoint. Lines render above/below
            // when this event has neighbors.
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : Color.secondary.opacity(0.3))
                    .frame(width: 2, height: 8)
                ZStack {
                    Circle()
                        .fill(event.color.opacity(0.18))
                        .frame(width: 28, height: 28)
                    Image(systemName: event.icon)
                        .foregroundColor(event.color)
                        .font(.system(size: 14, weight: .semibold))
                }
                Rectangle()
                    .fill(isLast ? Color.clear : Color.secondary.opacity(0.3))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                if !event.displayStamp.isEmpty {
                    Text(event.displayStamp)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Text(event.sentence)
                    .font(.callout)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .accessibilityIdentifier("fileJourney.event.\(event.kind.rawValue)")
    }

    // MARK: - Other copies disclosure

    @ViewBuilder
    private var copiesDisclosure: some View {
        DisclosureGroup(isExpanded: $showCopies) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(journey.otherKnownCopies) { copy in
                    copyRow(copy)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("\(journey.otherKnownCopies.count) other cop\(journey.otherKnownCopies.count == 1 ? "y" : "ies") known")
                .font(.callout.weight(.medium))
                .accessibilityIdentifier("fileJourney.copiesDisclosure")
        }
        .padding(8)
        .background(Color.green.opacity(0.04))
        .cornerRadius(6)
    }

    private func copyRow(_ copy: KnownCopy) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: copy.isSafe ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .foregroundColor(copy.isSafe ? .green : .orange)
                .font(.caption)
                .frame(width: 14)
            Text(copy.volumeName)
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundColor(copy.isSafe ? .primary : .secondary)
            Text("·")
                .foregroundColor(.secondary)
            Text(copy.role.rawValue)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("·")
                .foregroundColor(.secondary)
            Text(copy.trust.rawValue)
                .font(.caption2)
                .foregroundColor(.secondary)
            if !copy.isSafe {
                Text(copy.role == .retired ? "(retired)" : "(unreliable)")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
            Spacer()
            Text((copy.path as NSString).lastPathComponent)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .opacity(copy.isSafe ? 1.0 : 0.7)
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
