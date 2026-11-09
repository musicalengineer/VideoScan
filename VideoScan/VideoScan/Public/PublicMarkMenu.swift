// PublicMarkMenu.swift — the Archive row menu's Make Public / Make Private
// items and the globe that shows the bit (Rick 2026-11-09).
//
// Views, not a model extension (rule 12). The menu's body runs when the menu
// opens, on the clicked rows only: O(selection) digest lookups, O(1) store
// reads — never O(records). A click writes through PublicMarkStore, the one
// engine (rule 4); this file holds no SQL and no commit.
//
// What the menu offers, from the store's projection of the selection:
//   every one private   → Make Public            (Make N Public for several)
//   every one public    → Make Private
//   some of each        → both, each with its own count
//   anything public anywhere → Make Everything Private… (asks once)
// A selection holding a file that is not archived or has no full SHA-256, or
// a session that may not write (viewer, read-only, a job's hold), gets the
// items disabled with the reason as their tooltip.
//
// The globe is its own small view so that ONLY it re-renders when the bit
// changes — a row observes the store's revision, the Archive tab does not.
//
// (For Rick: `@ObservedObject` ≈ subscribing this view to the store's
// change signal; the tab that hosts it holds a plain reference and is not
// subscribed.)

import AppKit
import SwiftUI
import VideoScanCore

struct PublicMarkMenuItems: View {
    /// NOT observed (a mark change must not re-render an open menu): read
    /// once when the menu is built.
    let store: PublicMarkStore
    let targets: PublicMarkTargets

    /// Why the mark cannot be changed for this selection now; nil = it can.
    static func refusal(targets: PublicMarkTargets, writeRefusal: String?) -> String? {
        if let why = targets.refusal { return why }
        if targets.digests.isEmpty { return PublicMarkWords.noDigestHelp }
        return writeRefusal.map(PublicMarkWords.writeRefusalHelp)
    }

    /// Which of the two verbs the selection gets, with their counts (pure).
    struct Offer: Equatable {
        var makePublic: Int
        var makePrivate: Int

        init(total: Int, alreadyPublic: Int) {
            makePublic = total - alreadyPublic
            makePrivate = alreadyPublic
        }
    }

    var body: some View {
        if targets.total > 0 {
            let refusal = Self.refusal(targets: targets, writeRefusal: store.writeRefusal)
            let offer = Offer(total: targets.digests.count, alreadyPublic: store.publicCount(in: targets.digests))
            // A refused selection still shows Make Public (disabled, with why).
            if offer.makePublic > 0 || refusal != nil {
                Button {
                    change(to: true)
                } label: {
                    Label(PublicMarkWords.makePublicTitle(offer.makePublic), systemImage: "globe")
                }
                .disabled(refusal != nil)
                .help(refusal ?? PublicMarkWords.publicHelp)
                .accessibilityIdentifier("archive.row.makePublic")
            }
            if offer.makePrivate > 0, refusal == nil {
                Button {
                    change(to: false)
                } label: {
                    Label(PublicMarkWords.makePrivateTitle(offer.makePrivate), systemImage: "lock")
                }
                .help(PublicMarkWords.privateHelp)
                .accessibilityIdentifier("archive.row.makePrivate")
            }
        }
        if !store.publicDigests.isEmpty {
            Button(PublicMarkWords.makeEverythingPrivate) { everythingPrivate() }
                .disabled(store.writeRefusal != nil)
                .help(store.writeRefusal.map(PublicMarkWords.writeRefusalHelp) ?? PublicMarkWords.everythingPrivateExplanation)
                .accessibilityIdentifier("archive.row.makeEverythingPrivate")
        }
    }

    private func change(to isPublic: Bool) {
        if case .refused(let words) = store.set(isPublic, digests: targets.digests, files: targets.total) {
            PublicMarkDialogs.refused(words)
        }
    }

    private func everythingPrivate() {
        guard PublicMarkDialogs.confirmEverythingPrivate(count: store.publicDigests.count) else { return }
        if case .refused(let words) = store.makeEverythingPrivate() {
            PublicMarkDialogs.refused(words)
        }
    }
}

/// The globe beside an archived video that is public. Draws nothing for a
/// private one (private is the default and needs no mark).
struct PublicMarkBadge: View {
    @ObservedObject var store: PublicMarkStore
    /// The row's record; nil or no full SHA-256 = private, nothing drawn.
    let record: VideoRecord?
    var size: CGFloat = 13

    var body: some View {
        if store.isPublic(record.flatMap(CatalogCommit.digest(of:))) {
            Image(systemName: "globe")
                .font(.system(size: size))
                .foregroundStyle(.blue)
                .help(PublicMarkWords.badgeHelp)
                .accessibilityLabel(PublicMarkWords.badgeLabel)
                .accessibilityIdentifier("archive.row.public")
        }
    }
}

/// The two small native dialogs the public mark may show.
@MainActor
enum PublicMarkDialogs {

    /// false = cancelled.
    static func confirmEverythingPrivate(count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = PublicMarkWords.everythingPrivateQuestion(count)
        alert.informativeText = PublicMarkWords.everythingPrivateExplanation
        alert.addButton(withTitle: PublicMarkWords.everythingPrivateConfirm)
        alert.addButton(withTitle: PublicMarkWords.cancelButton)
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func refused(_ words: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = PublicMarkWords.refusedTitle
        alert.informativeText = words.prefix(1).uppercased() + words.dropFirst() + "."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
