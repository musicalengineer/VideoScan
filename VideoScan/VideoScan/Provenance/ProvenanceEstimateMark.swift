// ProvenanceEstimateMark.swift — the Archive tab's capture-master glyph, the
// row menu's Confirm Provenance / Provenance Not Right, and the Inspector's
// "Provenance (estimated): …" line (DECISIONS 2026-11-10).
//
// Views and one pure seam, not a model extension (rule 12). All the LOGIC is
// `ProvenanceEstimateMark` (pure, tested); the views only draw what it says.
// A click writes through ProvenanceEstimateStore, the one engine (rule 4);
// this file holds no SQL and no commit. Bodies do O(1) work per row: one
// digest lookup, two dictionary probes — never O(records).
//
// The glyph: a capture MASTER of a VHS tape gets a tape symbol. Estimated =
// secondary colour, help "Estimated: … — not confirmed". Confirmed = the same
// symbol with a small green check, help "…. Provenance confirmed by Rick."
// Never yellow (that is "no sound") and never red. Rick's own role
// (Provenance ▸ Set Role) wins: when he has set a different role, the
// estimate is not shown at all.
//
// The Inspector line reads catalog.sqlite for the selected content
// (`ProvenanceEstimateStore.readCurrent`, one index probe off the main
// actor) every time the selection or the store's revision moves — never the
// glyph's projection — and shows nothing until that read lands (most files
// have no estimate; a placeholder would flicker on every selection).
//
// (For Rick: `@ObservedObject` ≈ subscribing this small view to the store's
// change signal, so only the glyph re-renders when an estimate changes.)

import AppKit
import SwiftUI
import VideoScanCore

/// The pure seam: what is shown for one content, and with which symbol.
enum ProvenanceEstimateMark {

    struct Shown: Equatable {
        let symbol: String
        let isConfirmed: Bool
        let help: String
        let label: String
    }

    static let preferredSymbol = "recordingtape"
    static let fallbackSymbol = "film"

    /// `preferredSymbol` when this macOS has it, else `fallbackSymbol`.
    /// Resolved once (a lazy global — C++: a function-local static).
    static let symbolName: String = resolveSymbol { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }

    static func resolveSymbol(exists: (String) -> Bool) -> String {
        exists(preferredSymbol) ? preferredSymbol : fallbackSymbol
    }

    /// The estimate, unless Rick's own role says something else.
    static func visible(_ estimate: ProvenanceEstimate, rickRole: ProvenanceRole) -> ProvenanceEstimate? {
        rickRole == .unknown || rickRole == estimate.role ? estimate : nil
    }

    /// The glyph for one content: only a VHS capture master (estimated or
    /// confirmed) that Rick's own role does not contradict.
    static func judged(_ estimate: ProvenanceEstimate?, rickRole: ProvenanceRole, captured: Date?,
                       timeZone: TimeZone = .current) -> Shown? {
        guard let estimate, let seen = visible(estimate, rickRole: rickRole), seen.isVHSMaster,
              let help = ProvenanceResolver.shortLine(seen, captured: captured, timeZone: timeZone) else { return nil }
        return Shown(symbol: symbolName, isConfirmed: seen.isConfirmed, help: help,
                     label: seen.isConfirmed ? ProvenanceEstimateWords.glyphLabelConfirmed : ProvenanceEstimateWords.glyphLabelEstimated)
    }

    /// The Inspector's labelled line for `digest` from a reading of
    /// catalog.sqlite; nil = nothing to show (no estimate, a rejected one, a
    /// reading for another content, Rick's own role says otherwise).
    /// `year`: the archive's filing year (ProvenanceResolver.tapeYear).
    /// `masterName`: an alternate's master as the archive names it, or nil
    /// to drop the pointer (ProvenanceEstimateStore.masterName).
    static func inspectorLine(digest: String?, reading: ProvenanceEstimateStore.CurrentReading?, rickRole: ProvenanceRole,
                              year: Int?, captured: Date?, technical: ProvenanceResolver.Technical?,
                              masterName: (ProvenanceEstimate) -> String? = { _ in nil },
                              timeZone: TimeZone = .current) -> (text: String, isConfirmed: Bool)? {
        guard let digest, case .estimate(let readFor, let estimate)? = reading, readFor == digest.lowercased(),
              let seen = visible(estimate, rickRole: rickRole),
              let sentence = ProvenanceResolver.sentence(seen, year: year, captured: captured, technical: technical,
                                                         masterName: masterName(seen), timeZone: timeZone)
        else { return nil }
        return (ProvenanceResolver.labelledLine(seen, sentence: sentence), seen.isConfirmed)
    }

    /// What the row menu offers for a selection (pure).
    struct Offer: Equatable {
        /// Selected contents showing an unconfirmed estimate.
        var provisional: Int
        /// Why Confirm is disabled; nil = enabled.
        var confirmRefusal: String?
        /// Why Not Right is disabled; nil = enabled.
        var notRightRefusal: String?

        init(provisional: Int, writeRefusal: String?) {
            self.provisional = provisional
            let session = writeRefusal.map(ProvenanceEstimateWords.writeRefusalHelp)
            confirmRefusal = provisional == 0 ? ProvenanceEstimateWords.nothingToConfirmHelp : session
            // One at a time: a rejection cannot be taken back from the app.
            notRightRefusal = provisional == 1 ? session : ProvenanceEstimateWords.notRightNeedsOneHelp
        }
    }
}

/// The tape glyph beside an archived capture master. Draws nothing otherwise.
struct ProvenanceEstimateBadge: View {
    @ObservedObject var store: ProvenanceEstimateStore
    @ObservedObject var roles: ProvenanceRoleStore
    /// The row's record; nil or no full SHA-256 = nothing drawn.
    let record: VideoRecord?
    var size: CGFloat = 13

    var body: some View {
        let digest = record.flatMap(CatalogCommit.digest(of:))
        if let digest, let shown = ProvenanceEstimateMark.judged(store.estimate(of: digest), rickRole: roles.role(of: digest),
                                                                 captured: record?.embeddedCreationDate) {
            Image(systemName: shown.symbol)
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .overlay(alignment: .bottomTrailing) {
                    if shown.isConfirmed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: size * 0.6))
                            .foregroundStyle(.green)
                            .offset(x: size * 0.3, y: size * 0.2)
                    }
                }
                .padding(.trailing, shown.isConfirmed ? size * 0.3 : 0)
                .help(shown.help)
                .accessibilityLabel(shown.label)
                .accessibilityIdentifier("archive.row.provenance")
        }
    }
}

/// Confirm Provenance / Provenance Not Right, for the Archive row menu.
struct ProvenanceEstimateMenuItems: View {
    /// NOT observed (a change must not re-render an open menu): read once
    /// when the menu is built.
    let store: ProvenanceEstimateStore
    let roles: ProvenanceRoleStore
    /// The selection's distinct whole-file digests (files without one are simply not offered).
    let targets: ProvenanceRoleTargets

    var body: some View {
        if targets.total > 0 {
            let provisional = targets.digests.filter { store.shown(of: $0, roles: roles).map { !$0.isConfirmed } ?? false }
            let offer = ProvenanceEstimateMark.Offer(provisional: provisional.count, writeRefusal: store.writeRefusal ?? roles.writeRefusal)
            Button {
                if case .refused(let words) = store.confirm(digests: targets.digests, files: targets.total) {
                    ProvenanceEstimateDialogs.refused(words)
                }
            } label: {
                Label(ProvenanceEstimateWords.confirmTitle(offer.provisional), systemImage: "checkmark.seal")
            }
            .disabled(offer.confirmRefusal != nil)
            .help(offer.confirmRefusal ?? ProvenanceEstimateWords.confirmHelp)
            .accessibilityIdentifier("archive.row.confirmProvenance")

            Button {
                guard let digest = provisional.first else { return }
                if case .refused(let words) = store.reject(digest: digest) {
                    ProvenanceEstimateDialogs.refused(words)
                }
            } label: {
                Label(ProvenanceEstimateWords.notRightTitle, systemImage: "xmark.seal")
            }
            .disabled(offer.notRightRefusal != nil)
            .help(offer.notRightRefusal ?? ProvenanceEstimateWords.notRightHelp)
            .accessibilityIdentifier("archive.row.provenanceNotRight")
        }
    }
}

/// The Inspector's "Provenance (estimated): …" / "Provenance (confirmed by
/// Rick): …" line. Sits under InspectorProvenanceRoleLine.
struct InspectorProvenanceEstimateLine: View {
    let record: VideoRecord
    /// The selected file's whole-file digest (CatalogCommit.digest(of:)); nil = none yet.
    let digest: String?
    /// Where the archive holds this content (the row's "Archived To" file);
    /// nil = not archived. Its year folder is the sentence's "from <year>".
    let archivePath: String?
    @ObservedObject var store: ProvenanceEstimateStore
    @ObservedObject var roles: ProvenanceRoleStore
    /// The last finished read and the key it answered.
    @State private var completed: Completed?

    struct ReadKey: Equatable {
        let digest: String?
        let revision: Int
    }

    private struct Completed: Equatable {
        let key: ReadKey
        let reading: ProvenanceEstimateStore.CurrentReading
    }

    var body: some View {
        let key = ReadKey(digest: digest, revision: store.revision)
        let reading = completed?.key == key ? completed?.reading : nil
        let line = ProvenanceEstimateMark.inspectorLine(
            digest: digest, reading: reading, rickRole: digest.map { roles.role(of: $0) } ?? .unknown,
            year: ProvenanceResolver.tapeYear(archivePath: archivePath, captured: record.embeddedCreationDate),
            captured: record.embeddedCreationDate,
            technical: .init(videoCodec: record.videoCodec, resolution: record.resolution, bitDepth: record.bitDepth),
            masterName: { store.masterName(of: $0, roles: roles) })
        VStack(alignment: .leading, spacing: 0) {
            if let line {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if line.isConfirmed {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Confirmed")
                    }
                    Text(line.text)
                        .font(.callout)
                        .foregroundStyle(line.isConfirmed ? HierarchicalShapeStyle.primary : .secondary)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityIdentifier("catalog.inspector.provenanceEstimate")
            }
        }
        .task(id: key) {
            guard let digest = key.digest else { return }
            let now = await store.readCurrent(digest: digest)
            if !Task.isCancelled { completed = Completed(key: key, reading: now) }
        }
    }
}

/// The one small native dialog these verbs may show.
@MainActor
enum ProvenanceEstimateDialogs {

    static func refused(_ words: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ProvenanceEstimateWords.refusedTitle
        alert.informativeText = words.prefix(1).uppercased() + words.dropFirst() + "."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
